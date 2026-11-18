# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

「纪要」是 macOS 原生智能会议纪要应用：SwiftUI / Swift 6 负责业务与界面，audio.cpp 和 llama.cpp 作为两个独立的本机进程执行 Metal 推理。音频与文本不离开本机，运行时不依赖 Python。

环境要求：Apple Silicon、macOS 14+、Xcode 16+、CMake、Git、curl。完整安装与接口说明见 `README.md`。

## 常用命令

```bash
# 首次准备引擎和模型；不要使用 sudo
bash scripts/bootstrap.sh
bash scripts/download_models.sh

# 构建
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData build

# 运行
open DerivedData/Build/Products/Debug/Minutes.app

# 全部单元测试；CI 在 macOS 上运行同一命令
xcodebuild -project Minutes.xcodeproj -scheme Minutes \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData test
```

运行单个测试类或方法时，在上述 `test` 命令末尾追加：

```bash
-only-testing:MinutesTests/OpenAIStreamParserTests
-only-testing:MinutesTests/OpenAIStreamParserTests/testChineseAcrossEveryByteAndMultipleEvents
```

XCTest 宿主检测到 XCTest 后不会启动真实模型进程；网络测试使用 `URLProtocolStub`，不要求已下载模型。真实原生闭环验证使用 `bash scripts/verify_native.sh`，其 ASR/LLM/map-reduce 开关与输入格式见 `Benchmarks/README.md`。

## 核心架构与约束

- `MinutesApp` 注入 `MeetingsStore.shared`、`EngineSupervisor.shared` 和可选的 `MeetingSession`。这些 `@Observable` 状态对象承载业务状态，视图不直接管理音频或进程。
- `EngineSupervisor` 分别管理 ASR（`127.0.0.1:8797`）和 LLM（`127.0.0.1:8788`）的 `EngineWorker`。`EngineConfiguration` 持久化用户设置；`MINUTES_ENGINE_ROOT` / `MINUTES_MODELS_ROOT` 只覆盖未显式保存的默认路径。
- `EngineWorker` 可接管身份匹配的外部服务，但不会终止归属不明的进程。`EngineHealth` 的就绪判断必须继续验证运行时、Metal/构建信息、规范化模型路径和加载状态，不能仅凭 HTTP 200。
- `EngineClient` 是 actor：ASR 使用 PCM16 WAV multipart `/v1/audio/transcriptions`，LLM 使用 OpenAI 兼容的 `/v1/chat/completions` SSE。`OpenAIStreamParser` 将缺少 `[DONE]`、截断和服务端错误视为失败，防止保存不完整纪要。
- `AudioCaptureService` 必须以麦克风总线原生格式安装 tap，并为每个缓冲新建 `AVAudioConverter` 转成 16 kHz 单声道 float32；请求非原生 tap 格式曾导致 SIGSEGV，跨缓冲复用 converter 会静默丢数据。
- `MeetingSession` 不使用 VAD：每 1.5 秒识别当前完整缓冲，句末标点且至少 5 秒时落定，否则 15 秒强制切段，异常时最多保留 60 秒。`TranscriptionGate` 限制并发，`interimGeneration` 丢弃过期中间结果，`sequence` / `nextExpectedSequence` 保证正式片段有序。
- `MinutesComposer` 按 12000 字符切块，长会议使用 map-reduce；历史页重新生成复用 `generate`。结构化结果依赖 `## 摘要`、`## 决议`、`## 行动项`、`## 关键词` 四个 Markdown 小节。
- `MeetingsStore` 在 `~/Library/Application Support/Minutes/Meetings` 按会议 UUID 原子写入一个 JSON 文件。

## 原生依赖与模型

`Engine/dependencies.lock` 是上游提交、模型修订、字节数和 SHA256 的唯一锁定来源，升级时同步更新锁定值及验证。`Engine/.native/` 是生成目录，不是应修改的应用源码。构建、镜像回退和校验细节见 `README.md` 与 `scripts/`。

## Agent skills

### Issue tracker

Issues and specs are tracked as local Markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: a root `GLOSSARY.md` and `docs/adr/`. See `docs/agents/domain.md`.
