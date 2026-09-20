# 三栏式响应式字幕翻译系统

## How to Run

```bash
# 使用 Docker Compose 一键启动
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

## 自动化校验与发布流水线

`scripts/pipeline.sh` 把原来分散的手工步骤串成一条可重复执行的流程：

```
环境检查 → 安装依赖(npm ci) → 类型检查(tsc) → 构建静态产物 → 容器构建并启动服务 → 本机/容器一致性校验
```

```bash
scripts/pipeline.sh          # 完整流程(本机校验 + 容器发布),或 make pipeline
scripts/pipeline.sh --local  # 只跑本机部分,无 docker 的环境使用,或 make local
scripts/pipeline.sh --clean  # 先深度清理(node_modules/容器/镜像)再跑
scripts/pipeline.sh clean    # 只清理不运行,或 make clean
scripts/pipeline.sh -v       # 各阶段日志实时输出(默认只写日志文件)
```

- **哪一步卡住、什么原因**:每步有独立超时(超时被强制终止并标记「超时」),失败时终端显示
  步骤名、退出码和日志末尾,完整日志在 `.pipeline/logs/`,最后打印全流程汇总表。
- **改完重跑干净**:每次运行自动清理上一次的中间产物(重装依赖、清 dist、重建容器、重置日志),
  直接重跑同一条命令即可;`--clean` 额外清掉 node_modules 与容器镜像。
- **两处结果一致**:最后一步分别抓取本机预览(4173 端口)与容器服务(8081 端口)的页面及全部
  静态资源,逐个比对 sha256,不一致会 diff 出具体文件并判失败。
- 各阶段超时(秒)可用环境变量覆盖:`DEPS_TIMEOUT=600 TYPECHECK_TIMEOUT=180 BUILD_TIMEOUT=300
  CONTAINER_TIMEOUT=1200 WAIT_TIMEOUT=90 VERIFY_TIMEOUT=120`;容器地址可用 `CONTAINER_URL` 覆盖。
- macOS 需先 `brew install coreutils`(提供 timeout 命令)。

> 说明:`frontend-admin/.dockerignore` 排除了本机 `node_modules`/`dist`,否则它们会被
> `COPY . .` 带进镜像覆盖容器内依赖,导致容器构建与本机结果不一致。

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
