# OpenCodexBar 🍏🔊

[English](#english) | [简体中文](#简体中文)

---

<p align="center">
  <img src="preview_voice.png" alt="OpenCodexBar Widescreen Visualizer" width="800">
</p>

# English

**OpenCodexBar** is the premium, lightweight macOS companion client for **OpenCodex**. Running neatly in your macOS Status Bar, it provides global system-wide voice command hotkeys, real-time Audio-Reactive VAD, and a stunning widescreen floating frosted-glass visualizer capsule with full Mac Intelligence styling.

## 🌟 Key Features

* **Lightweight Companion App**: A native Swift client written with AppKit/Carbon, completely decoupled from AI prompt generation to maintain sandboxing safety and system stability.
* **Widescreen Floating Visualizer Capsule**:
  * Seamlessly floats above your macOS Dock (`24pt` raised offset).
  * Beautiful transparent glassmorphic depth (`backdrop-filter` blur + saturation) with absolutely 0px native OS square shadow boundaries.
  * Live dynamic 60fps waveform syncing and scrolling state text typewriter animations.
  * Fully supports customized visualizer themes (Vortex / Siri Fluid Wave / Capsule Local Glow / Scanning Halo) mapped dynamically from your dashboard.
* **Audio-Reactive VAD (Voice Activity Detection)**:
  * Injects a `0.4s` warm-up mic decibel filter spike suppression to avoid hardware clicks.
  * Real-time local amplitude metering feeding directly into visualizer ripples.
  * Autonomic silence detection (defaults to `1.5s`) automatically halts recording and pushes transcription to the local server.
* **Fast Global Hotkey (`Option-Space`) with Interrupt**: Toggle the visualizer HUD and microphone capture instantly. Pressing the hotkey while the AI is thinking, executing tools, or speaking will **instantly interrupt/stop** all operations, acts as a global **ESC** button.
* **Notch Drop Zone**: Includes an interactive camera notch drop zone supporting drag-and-drop file imports, text clippings, and universal screen images for instant model prompts. Features click-through safety to avoid blocking standard screen clicks.
* **Stable OS Entitlements**: Pre-signed with Designated Requirements (DR) matching bundle identifiers, resolving recurring macOS permission prompts permanently.
* **One-Click Session Management**: Click status bar options or trigger via keyboard shortcut (`Option-N`) to instantly clear agent session memory and start a clean conversation thread.

## 🛠️ Setup & Compilation

### Prerequisites
* macOS 12.0+ (Apple Silicon or Intel)
* Xcode Command Line Tools installed (Swift compiler `swiftc` / SPM)
* **OpenCodex** Node.js server running in the background (`http://localhost:8765`)

### Quick Build & Run

```bash
git clone https://github.com/AITabby/opencodex-bar.git
cd opencodex-bar
swift build -c release
open .build/release/OpenCodexBar
```

---

# 简体中文

**OpenCodexBar** 是 **OpenCodex** 的高颜值、轻量级 macOS 原生系统菜单栏（Status Bar）伴侣应用。它为您提供系统级的全局语音指令热键、麦克风分贝联动、实时 VAD 停顿检测，以及一个极其惊艳的极光流光悬浮毛玻璃胶囊（HUD Visualizer）。

## 🌟 核心特性

* **极致轻量架构**：基于 Swift (AppKit/Carbon) 编写的原生应用。采用“瘦客户端（Thin Client）”设计，完全剥离 AI 提示词运算和重型包依赖，保证沙箱（Sandbox）合规与 macOS 系统的极佳流畅度。
* **极光悬浮毛玻璃胶囊（HUD Visualizer）**：
  * 精准悬浮于 macOS Dock 栏上方（`24pt` 高度抬升），科技感拉满。
  * 完美的高维毛玻璃质感（`backdrop-filter` 20px 模糊 + 180% 饱和度），完全消除 macOS 原生窗口方形阴影残留，纯粹单胶囊悬浮。
  * 60fps 实时麦克风分贝波形联动与多行滚动打字机文本动画。
  * 支持控制台一键切换视觉主题（极光频谱 / Siri流体波形 / 胶囊边缘流光 / 赛博旋转扫描线）。
* **智能 VAD 噪音过滤与静音检测**：
  * 内置首个 `0.4` 秒硬件杂音/电流爆音抑制，避免灵敏度过高误触发。
  * 实时分贝幅值跟踪，同步渲染视觉动效。
  * 智能静音切分（默认 `1.5s`），说话完毕自动收尾并推送到本地服务器，无需手动点停。
* **全局唤醒热键 (`Option-Space`) 与一键打断**：一键录音及面板升起。当 AI 处于思考、工具运行（Computer Use）或正在播报语音时，再次按下快捷键可**立刻打断并中止**所有任务与音频播放，起到全局 **ESC** 键的作用。
* **极速拖拽刘海（Notch Drop Zone）**：内置屏幕顶部摄像头刘海交互拖拽区，完美支持各种跨屏/通用控制（Sidecar Universal Control）拖入的文件、文本片段以及网页图片，并自动转化为模型指令。具备点击穿透功能，完全不影响刘海下方的原生点击操作。
* **免除重复授权弹窗**：通过显式指定 Designated Requirement (DR) 授权关联机制并利用本地可信证书签名，完美修复了 macOS 因哈希变动导致每次启动重复弹出“无障碍授权”提示的顽固 Bug。
* **快捷会话重置**：点击菜单栏选项或使用系统快捷键（`Option-N`）一键清除 AI 记忆，开启全新对话。

## 🛠️ 编译与运行

### 运行环境
* macOS 12.0+ (支持 Apple Silicon M系列芯片 / Intel芯片)
* 系统已安装 Xcode Command Line Tools (支持 `swift` 编译指令)
* 本地已启动 **OpenCodex** 服务端网关 (`http://localhost:8765`)

### 快速构建

```bash
git clone https://github.com/AITabby/opencodex-bar.git
cd opencodex-bar
swift build -c release
open .build/release/OpenCodexBar
```
