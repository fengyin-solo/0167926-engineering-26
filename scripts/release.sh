#!/usr/bin/env bash
#
# release.sh — 实时字幕翻译系统：本地校验 + 容器发布 一键流水线
#
# 把原先分散的手工步骤串成一条可重复执行的流水线：
#   1. clean      清理上一次的中间产物（dist、node_modules、容器、旧镜像、日志）
#   2. deps       npm ci 干净安装锁定版本的第三方包
#   3. typecheck  TypeScript 严格类型检查
#   4. build      产出静态文件到 dist/
#   5. image      用【同一份 dist】构建容器镜像（容器内不再重复构建）
#   6. deploy     重建并启动容器服务
#   7. verify     HTTP 探活 + 本机预览 vs 容器服务 返回内容一致性比对
#
# 用法：
#   scripts/release.sh ci        # 本地校验：clean → deps → typecheck → build（不需要 Docker）
#   scripts/release.sh verify    # 只做一致性比对（要求 dist 已构建、容器已部署）
#   scripts/release.sh release   # 完整发布：clean → ... → 容器服务保持运行，最后通过一致性校验
#   scripts/release.sh clean     # 只清理
#
# 任意一步失败或超时都会：
#   - 立即终止，明确打印是【哪一步】失败、退出码/超时原因
#   - 该步骤的完整输出在 .release/logs/<步骤>.log（终端只打印末尾若干行）
#   - trap 回收启动的后台进程（如本机预览服务），不留孤儿进程
#
# 可配置的环境变量（均有默认值，超时单位：秒）：
#   TIMEOUT_DEPS / TIMEOUT_TYPECHECK / TIMEOUT_BUILD / TIMEOUT_IMAGE /
#   TIMEOUT_DEPLOY / TIMEOUT_WAIT_READY / TIMEOUT_VERIFY
#   HOST_PORT（默认 8081）、IMAGE_TAG（默认 latest）

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/frontend-admin"
DIST_DIR="${APP_DIR}/dist"
RELEASE_DIR="${ROOT_DIR}/.release"
LOG_DIR="${RELEASE_DIR}/logs"
LOG_FILE=""   # 当前步骤的日志文件，由 run_step 设置

SERVICE_NAME="frontend-admin"
CONTAINER_NAME="subtitle-translator-frontend"
IMAGE_NAME="subtitle-translator/frontend-admin"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
HOST_PORT="${HOST_PORT:-8081}"
PREVIEW_PORT="$(( HOST_PORT + 1000 ))"   # 本机预览临时端口，避免与容器端口冲突
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

# 各步骤超时（秒）
TIMEOUT_DEPS="${TIMEOUT_DEPS:-600}"
TIMEOUT_TYPECHECK="${TIMEOUT_TYPECHECK:-180}"
TIMEOUT_BUILD="${TIMEOUT_BUILD:-300}"
TIMEOUT_IMAGE="${TIMEOUT_IMAGE:-300}"
TIMEOUT_DEPLOY="${TIMEOUT_DEPLOY:-120}"
TIMEOUT_WAIT_READY="${TIMEOUT_WAIT_READY:-60}"
TIMEOUT_VERIFY="${TIMEOUT_VERIFY:-120}"

# 步骤在独立 bash 子进程中执行（见 run_with_timeout），把它们依赖的变量导出
export SCRIPT_DIR ROOT_DIR APP_DIR DIST_DIR RELEASE_DIR LOG_DIR
export SERVICE_NAME CONTAINER_NAME IMAGE_NAME IMAGE_TAG IMAGE_REF HOST_PORT PREVIEW_PORT COMPOSE_FILE
export TIMEOUT_DEPS TIMEOUT_TYPECHECK TIMEOUT_BUILD TIMEOUT_IMAGE TIMEOUT_DEPLOY TIMEOUT_WAIT_READY TIMEOUT_VERIFY
export C_RED C_GREEN C_YELLOW C_BLUE C_BOLD C_DIM C_RESET
export PREVIEW_PID LOG_FILE

# ---------------------------------------------------------------------------
# 颜色与输出
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

_step_start=0
_current_step=""

log()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
die()  { printf '%s\n' "${C_RED}✗ $*${C_RESET}" >&2; exit 1; }

on_error() {
  local exit_code=$?
  trap - ERR
  if [[ -n "${_current_step}" && -n "${LOG_FILE}" && -f "${LOG_FILE}" ]]; then
    printf '\n%s\n' "${C_RED}${C_BOLD}✗ 步骤 [${_current_step}] 失败（退出码 ${exit_code}）${C_RESET}" >&2
    printf '%s\n' "${C_RED}── ${LOG_FILE} 末尾输出 ──${C_RESET}" >&2
    tail -n 40 "${LOG_FILE}" >&2 || true
    printf '%s\n' "${C_RED}完整日志见：${LOG_FILE}${C_RESET}" >&2
  else
    printf '\n%s\n' "${C_RED}${C_BOLD}✗ 流水线异常退出（退出码 ${exit_code}）${C_RESET}" >&2
  fi
  exit "${exit_code}"
}
trap on_error ERR

# run_step <步骤名> <超时秒数> <步骤体（shell 代码，可引用本脚本的函数与变量）>
# 把整步输出写入日志文件，加超时控制；失败时由 on_error 统一汇报
run_step() {
  local name="$1"; shift
  local timeout_s="$1"; shift
  local step_code="$1"; shift
  _current_step="${name}"
  LOG_FILE="${LOG_DIR}/${name}.log"
  _step_start=$(date +%s)
  mkdir -p "${LOG_DIR}"
  : > "${LOG_FILE}"

  printf '\n%s %s\n' "${C_BLUE}${C_BOLD}==>${C_RESET} ${C_BOLD}[${name}]${C_RESET} ${C_DIM}（超时 ${timeout_s}s）${C_RESET}"

  local rc=0
  run_with_timeout "${timeout_s}" "${LOG_FILE}" "${step_code}" || rc=$?

  local elapsed=$(( $(date +%s) - _step_start ))
  if [[ ${rc} -eq 124 ]]; then
    printf '%s\n' "${C_RED}✗ [${name}] 超过 ${timeout_s}s 被终止${C_RESET}" >&2
    return 124
  elif [[ ${rc} -ne 0 ]]; then
    printf '%s\n' "${C_RED}✗ [${name}] 失败，退出码 ${rc}（耗时 ${elapsed}s）${C_RESET}" >&2
    return "${rc}"
  fi
  printf '%s\n' "${C_GREEN}✓ [${name}] 通过（${elapsed}s）${C_RESET}"
  _current_step=""
}

# 在独立 bash 子进程中执行步骤体（函数通过 declare -f 序列化、变量通过 export 传递）。
# setsid 建独立进程组，超时可整组杀掉，避免 npm/node/docker 等子进程残留。
# 看门狗每秒探活：步骤自然结束后 1s 内自行退出；超时则打标记并杀进程组，返回 124。
run_with_timeout() {
  local timeout_s="$1"; shift
  local logfile="$1"; shift
  local step_code="$1"; shift
  local marker="${logfile}.timeout"
  rm -f "${marker}"

  local payload='set -Eeuo pipefail; trap stop_preview EXIT; '"$(declare -f)"'; '"${step_code}"
  local pid watcher rc=0

  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "${payload}" >"${logfile}" 2>&1 &
  else
    # macOS 等无 setsid 的环境：退化为普通后台进程（超时只杀主进程）
    bash -c "${payload}" >"${logfile}" 2>&1 &
  fi
  pid=$!

  (
    local i
    for (( i = 0; i < timeout_s; i++ )); do
      kill -0 "${pid}" 2>/dev/null || exit 0
      sleep 1
    done
    touch "${marker}"
    if command -v setsid >/dev/null 2>&1; then
      kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    else
      kill -TERM "${pid}" 2>/dev/null || true
    fi
    sleep 2
    if command -v setsid >/dev/null 2>&1; then
      kill -KILL "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
    else
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  ) &
  watcher=$!

  wait "${pid}" || rc=$?
  kill "${watcher}" 2>/dev/null || true
  wait "${watcher}" 2>/dev/null || true

  if [[ -f "${marker}" ]]; then
    rm -f "${marker}"
    return 124
  fi
  return "${rc}"
}
# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

# 跨平台 sha256：Linux 一般有 sha256sum，macOS 只有 shasum
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 | awk '{print $1}'; }
else
  die "缺少 sha256sum 或 shasum，无法做一致性校验"
fi

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "未找到 docker。容器相关步骤无法执行；如只做本地校验请运行：scripts/release.sh ci"
  fi
  docker info >/dev/null 2>&1 || die "docker 守护进程不可用（docker info 失败），请先启动 Docker"
}

# ---------------------------------------------------------------------------
# 步骤 1：clean —— 保证重跑时没有上一次的中间产物
# ---------------------------------------------------------------------------
PREVIEW_PID=""
stop_preview() {
  local pid="${PREVIEW_PID:-}"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    info "停止本机预览进程 (pid ${pid})"
    # 预览以独立进程组（setsid）启动，杀整个进程组避免 vite/node 孤儿进程
    kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
  PREVIEW_PID=""
}
trap stop_preview EXIT

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "既没有 'docker compose' 也没有 'docker-compose'"
  fi
}

# 递归删除并在失败时重试一次：
# 个别文件系统（如 overlay 挂载）首次 rm -rf 可能瞬时 ENOTEMPTY
rm_retry() {
  local target="$1"
  rm -rf "${target}" 2>/dev/null || { sleep 1; rm -rf "${target}"; }
}

clean() {
  info "清理构建产物：${DIST_DIR#${ROOT_DIR}/}"
  rm_retry "${DIST_DIR}"

  info "清理本地依赖：frontend-admin/node_modules"
  rm_retry "${APP_DIR}/node_modules"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [[ -f "${COMPOSE_FILE}" ]]; then
      info "清理可能残留的容器（compose down --rmi local --volumes --remove-orphans）"
      compose -f "${COMPOSE_FILE}" down --rmi local --volumes --remove-orphans \
        >"${LOG_DIR}/clean.log" 2>&1 || true
    fi
    # 兜底：按固定容器名清理（可能由更早版本的脚本/手工启动）
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
      info "兜底删除残留容器：${CONTAINER_NAME}"
      docker rm -f "${CONTAINER_NAME}" >>"${LOG_DIR}/clean.log" 2>&1 || true
    fi
    info "清理悬空镜像层（dangling images）"
    docker image prune -f >>"${LOG_DIR}/clean.log" 2>&1 || true
  else
    info "docker 不可用，跳过容器/镜像清理"
  fi

  info "清理上一次的临时日志：${LOG_DIR#${ROOT_DIR}/}/"
  # 保留当前步骤自己的日志文件（它正被重定向写入），清空其余旧日志
  mkdir -p "${LOG_DIR}"
  find "${LOG_DIR}" -type f ! -name "$(basename "${LOG_FILE:-__none__}")" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 步骤 2~4：依赖、类型检查、构建（与容器镜像消费的是同一份 dist）
# ---------------------------------------------------------------------------
install_deps() {
  # 始终从干净的 node_modules 开始：
  # npm ci 虽然会自行清理，但遇到非 npm 管理的残留文件（如 .DS_Store）
  # 在部分文件系统上会报 ENOTEMPTY；显式删除最可靠，保证每次结果可重复。
  rm_retry "${APP_DIR}/node_modules"
  ( cd "${APP_DIR}" && npm ci )
}

typecheck() {
  ( cd "${APP_DIR}" && npx tsc --noEmit )
}

build() {
  ( cd "${APP_DIR}" && npx vite build )
}

# ---------------------------------------------------------------------------
# 步骤 5~6：用同一份 dist 构建镜像并起服务
# ---------------------------------------------------------------------------
build_image() {
  [[ -f "${DIST_DIR}/index.html" ]] \
    || die "dist/ 不存在或不完整（缺少 index.html）。镜像必须基于本地构建产物，请先执行 build 步骤"
  docker build -t "${IMAGE_REF}" -f "${APP_DIR}/Dockerfile" "${APP_DIR}"
}

deploy() {
  HOST_PORT="${HOST_PORT}" IMAGE_REF="${IMAGE_REF}" \
    compose -f "${COMPOSE_FILE}" up -d --force-recreate
}

# wait_ready <名称> <基础URL> <超时秒>
wait_ready() {
  local name="$1" base_url="$2" timeout_s="$3"
  local deadline=$(( $(date +%s) + timeout_s ))
  info "等待 ${name} 就绪：${base_url} （最长 ${timeout_s}s）"
  # 轮询期间的连接失败是正常的（服务还没起来），静默处理，由超时兜底报错
  until curl -fsS --silent -o /dev/null --max-time 3 "${base_url}/" 2>/dev/null; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      die "${name} 在 ${timeout_s}s 内未就绪（${base_url}/ 持续不可访问）"
    fi
    sleep 1
  done
  printf '%s\n' "${C_GREEN}✓ ${name} 已就绪${C_RESET}"
}

# ---------------------------------------------------------------------------
# 步骤 7：本机预览 vs 容器服务 一致性比对
#
# 两边服务的是同一份 dist 文件：逐个抓取 dist 中所有文件，比对 sha256，
# 任何一个文件 hash 不一致即判失败。
# ---------------------------------------------------------------------------
verify_parity() {
  local base_local="http://127.0.0.1:${PREVIEW_PORT}"
  # 默认对比本机容器；容器部署在远端/其他主机时可用 DOCKER_BASE_URL 覆盖
  local base_docker="${DOCKER_BASE_URL:-http://127.0.0.1:${HOST_PORT}}"

  require_cmd curl
  wait_ready "容器服务" "${base_docker}" "${TIMEOUT_WAIT_READY}"

  # 启动本机静态预览（vite preview 只服务 dist/，与 nginx 的静态服务等价）
  # setsid：独立进程组，结束时可整组回收，不留 vite/node 孤儿进程
  info "启动本机预览：${base_local}"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "cd '${APP_DIR}' && exec npx vite preview --port '${PREVIEW_PORT}' --strictPort --host 127.0.0.1" \
      >"${LOG_DIR}/verify-preview.log" 2>&1 &
  else
    ( cd "${APP_DIR}" && exec npx vite preview --port "${PREVIEW_PORT}" --strictPort --host 127.0.0.1 ) \
      >"${LOG_DIR}/verify-preview.log" 2>&1 &
  fi
  PREVIEW_PID=$!
  wait_ready "本机预览" "${base_local}" "${TIMEOUT_WAIT_READY}"

  local rel h_local h_docker failures=0 checked=0

  while IFS= read -r file; do
    rel="${file#${DIST_DIR}/}"
    h_local=$(curl -fsS --max-time 5 "${base_local}/${rel}" | sha256)
    h_docker=$(curl -fsS --max-time 5 "${base_docker}/${rel}" | sha256)
    checked=$(( checked + 1 ))
    if [[ "${h_local}" != "${h_docker}" ]]; then
      printf '%s\n' "${C_RED}  ✗ 内容不一致：/${rel}${C_RESET}"
      printf '    local  %s\n    docker %s\n' "${h_local}" "${h_docker}"
      failures=$(( failures + 1 ))
    else
      printf '%s %s\n' "${C_GREEN}  ✓${C_RESET}" "/${rel}"
    fi
  done < <(find "${DIST_DIR}" -type f | sort)

  # 额外验证 SPA 回退：未知路径都应返回 index.html
  local h_index h_fallback_local h_fallback_docker
  h_index=$(curl -fsS --max-time 5 "${base_local}/" | sha256)
  h_fallback_local=$(curl -fsS --max-time 5 "${base_local}/some/client/route" | sha256)
  h_fallback_docker=$(curl -fsS --max-time 5 "${base_docker}/some/client/route" | sha256)
  if [[ "${h_fallback_local}" == "${h_index}" && "${h_fallback_docker}" == "${h_index}" ]]; then
    printf '%s %s\n' "${C_GREEN}  ✓${C_RESET}" "SPA 回退路由（/some/client/route → index.html）"
  else
    printf '%s\n' "${C_RED}  ✗ SPA 回退行为不一致${C_RESET}"
    failures=$(( failures + 1 ))
  fi

  # 本机预览只是校验用的临时进程，校验结束即整组回收，不留后台进程
  stop_preview

  [[ ${checked} -gt 0 ]] || die "dist/ 中没有可校验的文件"
  if [[ ${failures} -ne 0 ]]; then
    die "一致性校验失败：${failures} 项不一致（共比对 ${checked} 个文件）"
  fi
  printf '%s\n' "${C_GREEN}${C_BOLD}✓ 本机预览与容器服务内容完全一致（${checked} 个文件 + SPA 回退）${C_RESET}"
}

# ---------------------------------------------------------------------------
# 流水线编排
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
用法: scripts/release.sh <命令>

命令:
  ci        本地校验流水线：clean → deps → typecheck → build
  verify    对已部署的服务做「本机预览 vs 容器」一致性比对
  release   完整发布：clean → deps → typecheck → build → image → deploy → verify
            （结束后容器服务保持运行：http://localhost:${HOST_PORT}）
  clean     只做清理（dist、容器、本地镜像、日志）

环境变量: HOST_PORT, IMAGE_TAG, TIMEOUT_*（见脚本顶部注释）
EOF
}

pipeline_ci() {
  require_cmd npm
  run_step clean 60 'clean'
  run_step deps "${TIMEOUT_DEPS}" 'install_deps'
  run_step typecheck "${TIMEOUT_TYPECHECK}" 'typecheck'
  run_step build "${TIMEOUT_BUILD}" 'build'
  log ""
  log "${C_GREEN}${C_BOLD}本地校验全部通过。${C_RESET}产物：${DIST_DIR#${ROOT_DIR}/}"
}

pipeline_release() {
  require_cmd npm
  require_docker
  run_step clean 120 'clean'
  run_step deps "${TIMEOUT_DEPS}" 'install_deps'
  run_step typecheck "${TIMEOUT_TYPECHECK}" 'typecheck'
  run_step build "${TIMEOUT_BUILD}" 'build'
  run_step image "${TIMEOUT_IMAGE}" 'build_image'
  run_step deploy "${TIMEOUT_DEPLOY}" 'deploy'
  run_step verify "${TIMEOUT_VERIFY}" 'verify_parity'
  log ""
  log "${C_GREEN}${C_BOLD}发布完成 ✓${C_RESET} 服务地址：http://localhost:${HOST_PORT}"
  info "容器：${CONTAINER_NAME}，镜像：${IMAGE_REF}"
}

pipeline_verify() {
  # 对比本机容器时需要 docker；用 DOCKER_BASE_URL 指向远端服务时不需要
  if [[ -z "${DOCKER_BASE_URL:-}" ]]; then
    require_docker
  fi
  [[ -f "${DIST_DIR}/index.html" ]] \
    || die "dist/ 尚未构建，请先运行：scripts/release.sh ci（或 release）"
  mkdir -p "${LOG_DIR}"
  run_step verify "${TIMEOUT_VERIFY}" 'verify_parity'
}

main() {
  mkdir -p "${LOG_DIR}"
  local cmd="${1:-}"
  case "${cmd}" in
    ci)      pipeline_ci ;;
    release) pipeline_release ;;
    verify)  pipeline_verify ;;
    clean)
      mkdir -p "${LOG_DIR}"
      run_step clean 120 'clean'
      log "${C_GREEN}清理完成${C_RESET}"
      ;;
    -h|--help|help|"") usage ;;
    *) usage; die "未知命令：${cmd}" ;;
  esac
}

main "$@"
