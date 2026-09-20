# 实时字幕翻译系统 — 常用入口(等价于直接调用 scripts/pipeline.sh)
.PHONY: pipeline local clean

pipeline: ## 完整流水线:环境检查→依赖→类型检查→构建→容器起服务→一致性校验
	./scripts/pipeline.sh

local: ## 只跑本机部分(无 docker 的环境使用)
	./scripts/pipeline.sh --local

clean: ## 清理全部中间产物(node_modules / dist / 容器与镜像 / 日志)
	./scripts/pipeline.sh clean
