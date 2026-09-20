# 三栏式响应式字幕翻译系统

## 发布流水线（推荐）

本地校验与容器发布统一由 `scripts/release.sh` 编排，把分散的手工步骤串成一条
可重复执行的流水线。每一步都有独立超时、分步日志；任意一步失败或超时会立即中断，
并明确指出是哪一步、退出码/超时原因，修好后重跑即可（开始前自动清理上一次的中间产物）。

```bash
# 本地校验：清理 → npm ci 装依赖 → TypeScript 类型检查 → vite 构建静态产物
scripts/release.sh ci

# 完整发布：上述步骤 → 用同一份 dist 构建镜像 → 容器方式起服务 → 一致性校验
scripts/release.sh release

# 只做「本机预览 vs 容器服务」内容一致性比对（要求 dist 已构建、容器已部署）
scripts/release.sh verify

# 只清理：dist、旧容器、本地镜像、流水线日志
scripts/release.sh clean
```

流水线步骤：

| 步骤 | 动作 | 默认超时 | 日志 |
|------|------|----------|------|
| clean | 删除 `dist/`、`compose down` 清理旧容器/本地镜像、旧日志 | 60/120s | `.release/logs/clean.log` |
| deps | 删除旧 `node_modules` 后 `npm ci`（按 lockfile 干净安装） | 600s | `.release/logs/deps.log` |
| typecheck | `tsc --noEmit` 严格类型检查 | 180s | `.release/logs/typecheck.log` |
| build | `vite build` 产出 `dist/` | 300s | `.release/logs/build.log` |
| image | `docker build`（只打包**本地已构建的同一份 dist**） | 300s | `.release/logs/image.log` |
| deploy | `docker compose up -d --force-recreate` | 120s | `.release/logs/deploy.log` |
| verify | HTTP 探活 + 逐个文件 sha256 比对 + SPA 回退检查 | 120s | `.release/logs/verify.log` |

失败时终端会打印失败步骤、退出码和日志末尾内容，完整输出在 `.release/logs/<步骤>.log`。
超时等阈值可用环境变量调整：`TIMEOUT_DEPS`、`TIMEOUT_TYPECHECK`、`TIMEOUT_BUILD`、
`TIMEOUT_IMAGE`、`TIMEOUT_DEPLOY`、`TIMEOUT_WAIT_READY`、`TIMEOUT_VERIFY`；
端口/镜像可用 `HOST_PORT`（默认 8081）、`IMAGE_TAG`（默认 latest）覆盖；
容器部署在其他主机时可用 `DOCKER_BASE_URL=http://<host>:<port> scripts/release.sh verify` 做远程一致性比对。

### 为什么「本机直接跑」与「容器方式起服务」结果相同？

- 静态产物只在本地构建一次（`npm ci` + `tsc` + `vite build` → `dist/`）；
- Docker 镜像**不再在容器内安装依赖/构建**，只是把这同一份 `dist/` 复制进 nginx 镜像
  （见 `frontend-admin/Dockerfile`、`.dockerignore`）；
- `verify` 步骤会实际抓取本机 `vite preview` 与容器 nginx 返回的每个文件做 sha256 比对，
  并验证未知路径都回退到 `index.html`，任何一个文件不一致即判失败。

发布成功后服务保持运行：http://localhost:8081

> 前置要求：`ci` 仅需 Node.js 20 + npm；`release` 还需要可用的 Docker
> （`docker compose` v2 或 `docker-compose` v1）。

## How to Run（手工方式）

```bash
# 使用 Docker Compose 一键启动（需先有本地构建产物 dist/，推荐用上面的 release 流水线）
docker-compose up -d --build

# 或者本地开发
cd frontend-admin
npm install
npm run dev
```

访问地址：http://localhost:8081

## Services

| 服务 | 端口 | 说明 |
|------|------|------|
| frontend-admin | 8081 | 字幕翻译前端应用 |

## 测试账号

本项目为纯前端应用，无需登录账号。

## 支持的翻译词汇

本项目使用本地词典进行翻译演示，支持以下常用词汇：

| 中文 | English |
|------|---------|
| 你好 | Hello |
| 早上好 | Good morning |
| 下午好 | Good afternoon |
| 晚上好 | Good evening |
| 晚安 | Good night |
| 谢谢 | Thank you / Thanks |
| 对不起 | Sorry |
| 再见 | Goodbye / Bye |
| 是的 | Yes |
| 不是 | No |
| 好的 | OK |
| 请 | Please |
| 欢迎 | Welcome |
| 你好吗 | How are you |
| 我爱你 | I love you |

> 注：不在词典中的词汇会显示 `[待翻译]` 或 `[Translation]` 前缀

## ⚠️ 浏览器兼容性说明

本项目使用 Web Speech API 实现语音识别功能，**需使用 Microsoft Edge 浏览器**。

### 为什么 Chrome 在国内无法使用？

Chrome 浏览器的 Web Speech API 实现是将音频发送到 **Google 云端服务器**进行处理。由于中国大陆无法直接访问 Google 服务，因此：
- 麦克风可以正常工作 ✅
- 能检测到声音和语音 ✅
- 但无法获得识别结果 ❌

### 浏览器支持情况

| 浏览器 | 语音识别 | 说明 |
|--------|----------|------|
| **Edge** | ✅ 推荐 | 使用微软 Azure 语音服务，国内可正常使用 |
| Chrome | ⚠️ 受限 | 使用 Google 语音服务，国内需要科学上网 |
| Firefox | ❌ 不支持 | 不支持 Web Speech API |
| Safari | ⚠️ 部分支持 | 功能受限 |

### 解决方案

1. **推荐**：使用 Microsoft Edge 浏览器访问

###  翻译功能实现 
- 使用本地Mock词典进行翻译演示，而非真实的翻译API


## 题目内容

请创建一个三栏式响应式布局的React组件，要求： 

左侧控制面板： 
- 固定宽度，深色背景毛玻璃效果 
- 包含语言选择下拉菜单、麦克风控制开关、音频设置滑块 
- 采用Tailwind CSS实现，支持动画交互 

中央字幕显示区： 
- 自适应宽度，支持滚动显示历史字幕 
- 中英文双语对照显示，当前识别内容高亮 
- 添加打字机动画效果 

右侧输入翻译区： 
- 固定宽度，包含文本输入框和翻译结果显示 
- 实现字符计数和发送按钮交互 

技术要求： 
- 使用CSS Grid和Flexbox实现布局 
- 所有组件采用TypeScript严格类型 
- 实现深色主题配色方案

## 项目介绍

本项目是一个现代化的实时字幕翻译系统前端界面，采用三栏式响应式布局设计：

- **左侧控制面板**：提供语言选择、麦克风控制、音量/语速调节等功能
- **中央字幕区**：实时显示识别的字幕内容，支持中英双语对照和打字机动画
- **右侧翻译区**：手动输入文本进行翻译，显示翻译结果

### 技术栈

- React 18 + TypeScript
- Vite 构建工具
- Tailwind CSS 样式框架
- Zustand 状态管理
- Lucide React 图标库

### 项目结构

```
├── README.md                    # 项目说明文档
├── docker-compose.yml           # Docker Compose 配置
├── .gitignore                   # Git 忽略文件
└── frontend-admin/              # 前端项目目录
    ├── Dockerfile               # Docker 构建文件
    ├── nginx.conf               # Nginx 配置
    ├── package.json             # 项目依赖
    ├── package-lock.json        # 依赖锁定文件
    ├── vite.config.ts           # Vite 配置
    ├── tailwind.config.js       # Tailwind CSS 配置
    ├── postcss.config.js        # PostCSS 配置
    ├── tsconfig.json            # TypeScript 配置
    ├── tsconfig.node.json       # Node 环境 TypeScript 配置
    ├── index.html               # HTML 入口
    ├── public/                  # 静态资源
    └── src/
        ├── main.tsx             # 应用入口
        ├── App.tsx              # 主应用组件
        ├── index.css            # 全局样式
        ├── components/          # 组件目录
        │   ├── ControlPanel/    # 左侧控制面板
        │   ├── SubtitleDisplay/ # 中央字幕显示
        │   ├── TranslationPanel/# 右侧翻译面板
        │   └── ui/              # 通用UI组件
        ├── hooks/               # 自定义Hooks
        ├── store/               # 状态管理
        ├── types/               # TypeScript类型定义
        └── utils/               # 工具函数
```
