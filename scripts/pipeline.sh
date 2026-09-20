#!/usr/bin/env bash
# =============================================================================
# pipeline.sh — 实时字幕翻译系统 本地校验与发布流水线
#
# 流程: 环境检查 → 安装依赖 → 类型检查 → 构建静态产物 → 容器起服务 → 一致性校验
#
# 用法:
#   scripts/pipeline.sh            完整流程(本机校验 + 容器发布)
#   scripts/pipeline.sh --local    只跑本机部分(无 docker 的环境使用)
#   scripts/pipeline.sh --clean    先深度清理(node_modules/容器/镜像)再跑
#   scripts/pipeline.sh clean      只清理,不运行
#   scripts/pipeline.sh -v         各阶段日志实时输出(默认只写入 .pipeline/logs/)
#
# 各阶段超时(秒)可用环境变量覆盖:
#   DEPS_TIMEOUT=600  TYPECHECK_TIMEOUT=180  BUILD_TIMEOUT=300
#   CONTAINER_TIMEOUT=1200  WAIT_TIMEOUT=90  VERIFY_TIMEOUT=120
#
# 任何一步失败/超时: 终端显示是哪一步、日志末尾内容,完整日志在 .pipeline/logs/
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/frontend-admin"
PIPELINE_DIR="$ROOT_DIR/.pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
COMPOSE=(docker compose -f "$ROOT_DIR/docker-compose.yml" -p subtitle-translator)

CONTAINER_URL="${CONTAINER_URL:-http://127.0.0.1:8081}"
LOCAL_PREVIEW_PORT="${LOCAL_PREVIEW_PORT:-4173}"
LOCAL_URL="http://127.0.0.1:${LOCAL_PREVIEW_PORT}"

DEPS_TIMEOUT="${DEPS_TIMEOUT:-600}"
TYPECHECK_TIMEOUT="${TYPECHECK_TIMEOUT:-180}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
CONTAINER_TIMEOUT="${CONTAINER_TIMEOUT:-1200}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"

LOCAL_ONLY="${LOCAL_ONLY:-0}"
VERBOSE="${VERBOSE:-0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
fi

# 内容摘要工具(一致性校验用)
if command -v sha256sum >/dev/null 2>&1; then
  HASH_BIN=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  HASH_BIN=(shasum -a 256)
else
  HASH_BIN=()
fi

# ---------------------------------------------------------------- 阶段定义 --

stage_preflight() {
  local missing=0
  for tool in node npm curl; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "✓ $tool -> $(command -v "$tool")"
    else
      echo "✗ 缺少命令: $tool"; missing=1
    fi
  done
  echo "  node $(node --version 2>/dev/null || echo '?'), npm $(npm --version 2>/dev/null || echo '?')"
  if [[ ! -f "$APP_DIR/package-lock.json" ]]; then
    echo "✗ 缺少 frontend-admin/package-lock.json(npm ci 依赖锁文件保证可重复安装)"
    missing=1
  fi
  if [[ ${#HASH_BIN[@]} -eq 0 ]]; then
    echo "✗ 缺少 sha256sum / shasum(一致性校验需要)"; missing=1
  fi
  if [[ "$LOCAL_ONLY" != "1" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      echo "✗ 未安装 docker,无法执行容器阶段(只验证本机流程请加 --local)"; missing=1
    elif ! docker info >/dev/null 2>&1; then
      echo "✗ docker 守护进程不可用(未启动或当前用户无权限)"; missing=1
    elif ! docker compose version >/dev/null 2>&1; then
      echo "✗ docker compose 插件不可用"; missing=1
    else
      echo "✓ docker server $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
    fi
  fi
  [[ $missing -eq 0 ]] || { echo "环境检查未通过,请按上面提示处理"; exit 1; }
  echo "环境检查通过"
}

stage_deps() {
  cd "$APP_DIR"
  echo ">> 先自行删除 node_modules(避免 npm ci 内部 rmdir 在挂载盘上偶发 ENOTEMPTY)"
  rm -rf node_modules
  echo ">> npm ci(严格按锁文件安装,保证可重复)"
  npm ci --no-audit --no-fund
}

stage_typecheck() {
  cd "$APP_DIR"
  npm run typecheck
}

stage_build() {
  cd "$APP_DIR"
  echo ">> 清理上一次构建产物 dist/"
  rm -rf dist
  if npm run build; then
    echo ">> 构建产物清单:"
    find dist -type f | LC_ALL=C sort
    du -sh dist
  else
    echo ">> 构建失败,清除可能残留的半成品 dist/"
    rm -rf dist
    exit 1
  fi
}

stage_container() {
  cd "$ROOT_DIR"
  echo ">> 停止并移除上一次运行的容器(如有)"
  "${COMPOSE[@]}" down --remove-orphans || true
  echo ">> 构建镜像"
  "${COMPOSE[@]}" build
  echo ">> 启动服务"
  "${COMPOSE[@]}" up -d
  echo ">> 等待服务就绪: $CONTAINER_URL (上限 ${WAIT_TIMEOUT}s)"
  if ! wait_url "$CONTAINER_URL" "$WAIT_TIMEOUT"; then
    echo "!! 服务 ${WAIT_TIMEOUT}s 内未就绪,容器状态与最近日志:"
    "${COMPOSE[@]}" ps || true
    "${COMPOSE[@]}" logs --tail=80 || true
    exit 1
  fi
  echo "服务已就绪: $CONTAINER_URL"
}

stage_verify() {
  cd "$APP_DIR"
  [[ -f dist/index.html ]] || { echo "缺少 dist/index.html,构建产物不完整"; exit 1; }

  echo ">> 启动本机静态预览: $LOCAL_URL"
  npx --no-install vite preview --port "$LOCAL_PREVIEW_PORT" --strictPort --host 127.0.0.1 \
    >"$LOG_DIR/preview.out" 2>&1 &
  PREVIEW_PID=$!
  trap cleanup_preview EXIT
  if ! wait_url "$LOCAL_URL" 30; then
    echo "!! 本机预览 30s 内未就绪,预览进程输出:"
    cat "$LOG_DIR/preview.out"
    exit 1
  fi

  local work
  work="$(mktemp -d "$PIPELINE_DIR/verify.XXXXXX")"
  echo ">> 抓取本机预览内容"
  fetch_tree "$LOCAL_URL" "$work/local"

  if [[ "$LOCAL_ONLY" == "1" ]]; then
    echo ">> --local 模式:本机预览及其引用的全部静态资源均可正常访问"
    rm -rf "$work"
    return 0
  fi

  echo ">> 抓取容器服务内容: $CONTAINER_URL"
  fetch_tree "$CONTAINER_URL" "$work/container"

  echo ">> 比对两处内容摘要(${HASH_BIN[*]})"
  make_manifest "$work/local"     > "$work/local.manifest"
  make_manifest "$work/container" > "$work/container.manifest"
  if diff -u "$work/local.manifest" "$work/container.manifest"; then
    echo ">> 一致性校验通过:本机直接跑与容器方式起服务,内容完全一致"
    rm -rf "$work"
  else
    echo "!! 本机与容器内容不一致,差异见上方 diff(目录保留在 $work 供排查)"
    exit 1
  fi
}

# ---------------------------------------------------------------- 辅助函数 --

wait_url() {  # wait_url <url> <seconds>
  local deadline=$((SECONDS + $2))
  until curl -fsS -o /dev/null "$1"; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

fetch_tree() {  # fetch_tree <base-url> <dest-dir>:下载首页及其引用的全部静态资源
  local base="$1" dest="$2" path
  mkdir -p "$dest"
  curl -fsS "$base/" -o "$dest/index.html"
  { grep -oE '(/[A-Za-z0-9._-]+)+\.(js|css|svg|png|jpg|jpeg|ico|woff2?)' "$dest/index.html" || true; } \
    | LC_ALL=C sort -u | while read -r path; do
        mkdir -p "$dest$(dirname "$path")"
        curl -fsS "$base$path" -o "$dest$path"
      done
}

make_manifest() {  # make_manifest <dir>:输出该目录所有文件的 路径+摘要 清单
  (cd "$1" && find . -type f | LC_ALL=C sort | xargs "${HASH_BIN[@]}")
}

cleanup_preview() {
  [[ -n "${PREVIEW_PID:-}" ]] && kill "$PREVIEW_PID" 2>/dev/null || true
  pkill -f "vite preview.*${LOCAL_PREVIEW_PORT}" 2>/dev/null || true
}

# 内部入口:run_stage 用 `timeout N pipeline.sh __stage <name>` 的方式给阶段加超时
if [[ "${1:-}" == "__stage" ]]; then
  shift
  case "${1:-}" in
    preflight|deps|typecheck|build|container|verify) "stage_$1" ;;
    *) echo "内部错误:未知阶段 '${1:-}'" >&2; exit 2 ;;
  esac
  exit
fi

# -------------------------------------------------------------- 主流程 ------

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

ORIG_ARGS="$*"
DEEP_CLEAN=0
CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)        LOCAL_ONLY=1 ;;
    --clean)        DEEP_CLEAN=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    clean)          CLEAN_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
  shift
done
export LOCAL_ONLY VERBOSE

deep_clean() {
  echo ">> 深度清理:node_modules / dist / .pipeline / 容器与本地镜像"
  rm -rf "$APP_DIR/node_modules" "$APP_DIR/dist" "$PIPELINE_DIR"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    "${COMPOSE[@]}" down -v --remove-orphans --rmi local || true
  fi
}

if [[ $CLEAN_ONLY -eq 1 ]]; then
  deep_clean
  echo "清理完成"
  exit 0
fi

# timeout 命令是阶段超时的基础(macOS 需 brew install coreutils 提供 gtimeout)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=(timeout -k 10)
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=(gtimeout -k 10)
else
  echo "缺少 timeout 命令,无法限制阶段耗时(macOS 请执行: brew install coreutils)" >&2
  exit 1
fi

STAGE_NAMES=(); STAGE_STATUS=(); STAGE_SECS=()
STAGE_IDX=0
TOTAL_STAGES=6
[[ "$LOCAL_ONLY" == "1" ]] && TOTAL_STAGES=5

print_summary() {
  echo
  echo "==================== 流水线汇总 ===================="
  local i st color
  for i in "${!STAGE_NAMES[@]}"; do
    st="${STAGE_STATUS[$i]}"
    color="$C_GREEN"; [[ "$st" == "通过" ]] || color="$C_RED"
    printf '  %s[%s]%s %s(耗时 %ss)\n' "$color" "$st" "$C_OFF" "${STAGE_NAMES[$i]}" "${STAGE_SECS[$i]}"
  done
  [[ "$LOCAL_ONLY" == "1" ]] && printf '  %s[跳过]%s 容器构建并启动服务(--local 模式)\n' "$C_YELLOW" "$C_OFF"
  echo "==================================================="
}

run_stage() {  # run_stage <key> <标题> <超时秒>
  local key="$1" title="$2" limit="$3"
  STAGE_IDX=$((STAGE_IDX + 1))
  local rel_log=".pipeline/logs/$(printf '%02d' "$STAGE_IDX")-$key.log"
  local log="$ROOT_DIR/$rel_log"
  printf '\n%s[%d/%d] %s%s(超时上限 %ss,日志 %s)\n' \
    "$C_BOLD" "$STAGE_IDX" "$TOTAL_STAGES" "$title" "$C_OFF" "$limit" "$rel_log"
  local start=$SECONDS rc=0
  if [[ "$VERBOSE" == "1" ]]; then
    # pipefail 下管道整体返回 timeout 的状态,用 || 捕获避免触发 set -e
    "${TIMEOUT_BIN[@]}" "$limit" "$ROOT_DIR/scripts/pipeline.sh" __stage "$key" 2>&1 | tee "$log" || rc=$?
  else
    "${TIMEOUT_BIN[@]}" "$limit" "$ROOT_DIR/scripts/pipeline.sh" __stage "$key" >"$log" 2>&1 || rc=$?
  fi
  local dur=$((SECONDS - start))
  STAGE_NAMES+=("$title"); STAGE_SECS+=("$dur")
  if [[ $rc -eq 0 ]]; then
    STAGE_STATUS+=("通过")
    printf '  %s✓ 通过%s(耗时 %ss)\n' "$C_GREEN" "$C_OFF" "$dur"
    return 0
  fi
  local reason="失败"
  [[ $rc -eq 124 || $rc -eq 137 ]] && reason="超时(>${limit}s,已强制终止)"
  STAGE_STATUS+=("$reason")
  printf '  %s✗ %s%s(耗时 %ss,退出码 %s)\n' "$C_RED" "$reason" "$C_OFF" "$dur" "$rc"
  echo "  ---- 日志末尾($rel_log)----"
  tail -n 30 "$log" | sed 's/^/  │ /'
  print_summary
  printf '\n%s流水线中止:第 %d 步「%s」%s。%s\n' "$C_RED" "$STAGE_IDX" "$title" "$reason" "$C_OFF"
  echo "修复后重新执行: scripts/pipeline.sh ${ORIG_ARGS}(各阶段会自动清理上一次的中间产物)"
  exit "$rc"
}

echo "==================================================="
echo " 实时字幕翻译系统 · 校验与发布流水线"
echo " 时间: $(date '+%F %T')  模式: $([[ "$LOCAL_ONLY" == "1" ]] && echo '仅本机' || echo '本机+容器')"
echo "==================================================="

# 每次运行都从干净状态开始:清掉上次日志,按需深度清理
rm -rf "$PIPELINE_DIR"
mkdir -p "$LOG_DIR"
[[ $DEEP_CLEAN -eq 1 ]] && deep_clean && mkdir -p "$LOG_DIR"

run_stage preflight "环境检查"               60
run_stage deps       "安装第三方依赖(npm ci)" "$DEPS_TIMEOUT"
run_stage typecheck  "类型检查(tsc)"          "$TYPECHECK_TIMEOUT"
run_stage build      "构建静态产物"            "$BUILD_TIMEOUT"
if [[ "$LOCAL_ONLY" != "1" ]]; then
  run_stage container "容器构建并启动服务"      "$CONTAINER_TIMEOUT"
fi
run_stage verify     "一致性校验"              "$VERIFY_TIMEOUT"

print_summary
if [[ "$LOCAL_ONLY" == "1" ]]; then
  printf '\n%s本机流程全部通过。%s完整发布(含容器)请执行: scripts/pipeline.sh\n' "$C_GREEN" "$C_OFF"
else
  printf '\n%s全部通过 ✓%s 服务地址: %s\n' "$C_GREEN" "$C_OFF" "$CONTAINER_URL"
  echo "停止服务: ${COMPOSE[*]} down"
fi
