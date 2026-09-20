# 生产镜像：静态产物由流水线在本地统一构建（npm ci + tsc + vite build），
# 镜像只负责打包【同一份 dist】并用 nginx 提供服务。
# 这样「本机直接跑」与「容器方式起服务」的静态文件完全一致，
# 也避免容器内重复安装依赖、重复构建带来的差异。
#
# 构建前置条件：dist/ 已存在（由 scripts/release.sh 的 build 步骤保证）
FROM nginx:alpine

# 复制本地构建产物与 nginx 配置
COPY dist/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

# nginx 镜像自带的 HEALTHCHECK 不可用（alpine 无 curl），用 wget 做探活
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
