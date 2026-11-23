# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

「纪要」是 macOS 原生智能会议纪要应用：SwiftUI / Swift 6 负责业务与界面，audio.cpp 和 llama.cpp 作为两个独立的本机进程执行 Metal 推理。音频与文本不离开本机，运行时不依赖 Python。

环境要求：Apple Silicon、macOS 14+、Xcode 16+（含 Metal 编译器）、CMake、Git、curl。Xcode 工程只有 `Minutes` scheme，以及 `Minutes` / `MinutesTests` 两个 target。

## 常用命令

### 首次准备引擎和模型

```bash
bash scripts/bootstrap.sh
bash scripts/download_models.sh
open Minutes.xcodeproj
```

三个脚本均不要使用 `sudo`；默认安装到当前用户的 `~/Library/Application Support/Minutes`。`bootstrap.sh` 按固定提交构建 Release + Metal 服务，`download_models.sh` 下载 GGUF 并校验字节数与 SHA256。

### 构建和运行

```bash
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData build

open DerivedData/Build/Products/Debug/Minutes.app
```

应用启动时自动启动两个推理进程；首次录音需在系统设置中授予麦克风权限。

### 单元测试

```bash
# 全部测试
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData test

# 单个测试类
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData test \
  -only-testing:MinutesTests/OpenAIStreamParserTests

# 单个测试方法
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData test \
  -only-testing:MinutesTests/OpenAIStreamParserTests/testChineseAcrossEveryByteAndMultipleEvents
```

XCTest 使用应用作为测试宿主，但 `AppDelegate` 检测到 XCTest 后不会启动真实模型进程。网络客户端测试通过 `URLProtocolStub` 拦截请求，不要求已下载模型。

### 真实原生闭环验证

```bash
# 仅验证两个 worker 的启动、健康检查和停止
bash scripts/verify_native.sh

# 加入真实 ASR 与 LLM 请求；ASR 输入是 16 kHz 单声道 float32 原始 PCM，不是 WAV
MINUTES_SMOKE_ASR=/path/to/real_zh_16k.f32 \
MINUTES_SMOKE_LLM=1 \
bash scripts/verify_native.sh

# 在上述命令上追加，验证长文本 map-reduce
MINUTES_SMOKE_MAP_REDUCE=1
```

该脚本直接编译生产版 `EngineWorker`、`EngineClient` 等源码，需先完成引擎构建和模型下载。性能测量方法与结果见 `Benchmarks/README.md`。

## 核心架构

### 应用状态与视图

`MinutesApp` 持有 `MeetingsStore.shared`、`EngineSupervisor.shared` 和可选的当前 `MeetingSession`，通过 SwiftUI environment 注入视图。`MeetingSession`、`MeetingsStore`、`EngineSupervisor` 使用 `@Observable`；前两者及 Supervisor 均在 `@MainActor` 上。视图只观察状态和调用会话/Supervisor，不直接管理音频或进程。

### 本机推理进程

- `EngineSupervisor` 分别管理 ASR 与 LLM 的 `EngineWorker`；默认地址为 `127.0.0.1:8797` 和 `127.0.0.1:8788`。
- `EngineConfiguration` 将用户设置存入 `UserDefaults`。`MINUTES_ENGINE_ROOT`、`MINUTES_MODELS_ROOT` 只覆盖默认引擎/模型路径，已显式保存的用户路径优先。
- `EngineWorker` 负责启动、退出、日志和崩溃恢复。启动前会探测端口，可接管身份匹配的外部服务，但不会终止归属不明的进程；配置签名变化会触发重启。
- 就绪不只看 HTTP 200：`EngineHealth` 还验证运行时类型、Metal/构建信息、规范化后的模型路径及模型加载状态。修改生命周期逻辑时不能把任意占用端口的服务误判为就绪。
- ASR 配置由 `ASRServerConfiguration` 写入 `engine/runtime/asr-<port>.json`；LLM 参数由 `EngineWorker` 直接传递，当前为 32768 context、单请求槽位、关闭 reasoning。

### 标准协议边界

`EngineClient` 是 actor。ASR 将 16 kHz 单声道 float32 转为 PCM16 WAV，以 multipart POST 到 `/v1/audio/transcriptions`；LLM 使用 OpenAI 兼容的 `/v1/chat/completions` SSE。不要在这两层之间重新引入私有 Python 协议。`OpenAIStreamParser` 会将缺少 `[DONE]`、截断或服务端错误视为失败，避免把不完整纪要当成功结果保存。

### 采集、识别与分段

`AudioCaptureService` 在麦克风总线的原生格式上安装 tap，再为每个缓冲新建 `AVAudioConverter` 转成 16 kHz 单声道 float32。不要改成请求非原生 tap 格式或跨缓冲复用 converter：前者曾导致 SIGSEGV，后者会因 converter 内部状态静默丢数据。

`MeetingSession` 不使用 VAD：每 1.5 秒识别一次当前完整缓冲，句末标点且至少 5 秒时落定，否则 15 秒强制切段；引擎异常时缓冲最多保留 60 秒。`TranscriptionGate` 限制 ASR 并发，中间识别允许丢弃，结束冲刷必须排队。`interimGeneration` 用于丢弃切段前发出的过期结果，`sequence` / `nextExpectedSequence` 用于按序归位正式片段。

### 纪要生成与持久化

结束会议时依次冲刷剩余音频、流式生成纪要、生成标题并保存。`MinutesComposer` 按 12000 字符切块；长会议采用逐块压缩再汇总的 map-reduce，历史页“重新生成”也复用其 `generate` 入口。结构化结果依赖 `## 摘要`、`## 决议`、`## 行动项`、`## 关键词` 四个 Markdown 小节。

`MeetingsStore` 在 `~/Library/Application Support/Minutes/Meetings` 中按会议 UUID 保存一个格式化 JSON 文件，采用原子写入。历史纪要重新生成和标题编辑都通过同一 Store 保存。

## 原生依赖与模型

`Engine/dependencies.lock` 是上游提交、模型修订、下载地址、字节数和 SHA256 的唯一锁定来源，Shell 脚本会直接 source 它。升级引擎或模型时同步更新锁定值及相关验证；`Engine/.native/` 是生成/下载的源码与构建目录，不属于应修改的应用源码。模型下载优先 ModelScope，随后回退到镜像和 Hugging Face，但最终文件必须通过锁定校验。
