# 纪要（Minutes）

macOS 原生智能会议纪要应用。音频与文本只在本机处理，不上传到云端。

项目主页：<https://wang-junjian.github.io/Minutes/>（含架构、流水线与性能说明）· 深入版：<https://wang-junjian.github.io/Minutes/architecture.html>

- **ASR**：[audio.cpp](https://github.com/0xShug0/audio.cpp) + Qwen3-ASR-1.7B Q8_0 GGUF（Metal）
- **LLM**：[llama.cpp](https://github.com/ggml-org/llama.cpp) + Qwen3.5-4B Q4_K_M GGUF（Metal）
- **应用**：SwiftUI / Swift 6；推理、构建、模型下载均不依赖 Python

## 架构

```
┌────────────────────────── macOS App（SwiftUI / Swift 6）──────────────────────────┐
│  Views ← MeetingSession ← AudioCapture（16 kHz / 单声道）    EngineSupervisor     │
│     ↑            ↓ async stream                             ↓ 进程管理/健康检查    │
│  MeetingsStore(JSON 落盘)   EngineClient(actor, WAV multipart / OpenAI SSE)        │
└──────────┬───────────────────────────────┬─────────────────────────────────────────┘
           │ 127.0.0.1:8797                │ 127.0.0.1:8788
┌──────────▼──────────────┐     ┌──────────▼──────────────┐
│ audiocpp_server         │     │ llama-server            │
│ Qwen3-ASR-1.7B Q8_0     │     │ Qwen3.5-4B Q4_K_M       │
│ audio.cpp / Metal       │     │ llama.cpp / Metal       │
└─────────────────────────┘     └─────────────────────────┘
```

设计原则：

1. **标准协议**：ASR 使用 WAV multipart，LLM 使用 OpenAI Chat Completions SSE，不维护私有 Python 协议适配层。
2. **分进程隔离**：两个原生服务独立加载模型、独立崩溃恢复；只监听本机回环地址。
3. **业务层复用**：会议状态机、分段归位、时间戳、Prompt、map-reduce 和 JSON 持久化均留在 Swift。
4. **健康身份校验**：同时检查运行时、模型路径和模型加载状态，不会把旧 worker 或端口上的其他服务误判为就绪。

## 环境要求

- Apple Silicon Mac（arm64），macOS 14.0 或更高版本
- Xcode 16+（包含 Metal 编译器）、CMake、Git、curl
- 首次构建和模型下载需要足够磁盘空间；两个 GGUF 合计约 5 GB

## 快速开始

```bash
# 1. 构建并安装固定提交的 audio.cpp / llama.cpp（Release + Metal）
bash scripts/bootstrap.sh

# 2. 下载固定修订的 GGUF，并验证字节数与 SHA256
bash scripts/download_models.sh

# 3. 打开工程
open Minutes.xcodeproj
```

三个脚本都不要加 `sudo`：引擎和模型安装在当前用户的 `~/Library/Application Support/Minutes`，用 root 运行会改为查找 root 的目录，导致应用找不到文件。

首次运行时在系统设置中允许「纪要」使用麦克风。应用启动后会自动加载语音识别和语言模型，主界面工具栏会实时显示模型状态；语音识别就绪后即可新建会议，也可在状态菜单中手动启停。会议结束后，双击纪要页标题即可修改并自动保存。

默认安装位置：

```text
~/Library/Application Support/Minutes/
├── engine/bin/                 # audiocpp_server、llama-server
└── models/
    ├── Qwen3-ASR-1.7B-GGUF/qwen3-asr-1.7b-q8_0.gguf
    └── Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf
```

可用 `MINUTES_ENGINE_ROOT` 覆盖引擎目录、`MINUTES_MODELS_ROOT` 覆盖模型目录。下载脚本优先使用 ModelScope 镜像，失败后回退到 `hf-mirror.com` 与 Hugging Face 官方源；也可用 `MINUTES_HF_ENDPOINT` 指定回退来源。镜像只影响传输，最终都必须通过 `Engine/dependencies.lock` 中的固定字节数与 SHA256 校验。

## 引擎接口

| 服务 | 端点 | 说明 |
|-|-|-|
| ASR | `GET /health`、`GET /v1/models` | 运行时与模型加载状态 |
| ASR | `POST /v1/audio/transcriptions` | multipart WAV，`model=minutes-asr` |
| LLM | `GET /health`、`GET /props` | 就绪状态、构建信息和模型路径 |
| LLM | `POST /v1/chat/completions` | OpenAI 兼容，`model=minutes-llm`，SSE 逐块输出 |

手动启动示例：

```bash
ENGINE_ROOT="$HOME/Library/Application Support/Minutes/engine"
MODELS_ROOT="$HOME/Library/Application Support/Minutes/models"

"$ENGINE_ROOT/bin/llama-server" \
  --model "$MODELS_ROOT/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf" \
  --alias minutes-llm --host 127.0.0.1 --port 8788 \
  --ctx-size 32768 --parallel 1 --gpu-layers all --reasoning off
```

ASR 的 JSON 配置由应用根据当前模型路径和端口自动生成到 `engine/runtime/asr-<port>.json`。

## 目录

```
Minutes/
├── Minutes.xcodeproj/          # 应用与单元测试 target
├── Minutes/                    # SwiftUI、采集、会议、引擎客户端
├── MinutesTests/               # SSE、WAV、健康检查与配置迁移测试
├── Engine/
│   ├── dependencies.lock       # 上游提交、模型修订、字节数与 SHA256
│   └── .native/                # 生成的源码与构建目录（不入库）
├── Benchmarks/                 # 性能对照与真实原生闭环验证
└── scripts/
    ├── bootstrap.sh            # 原生 Metal 构建与安装
    ├── download_models.sh      # 无 Python 的模型下载与校验
    └── verify_native.sh        # 真实 worker + EngineClient 闭环验证
```

## 从旧版升级

1. 先退出旧版应用并停止旧推理进程。新版不会自动终止端口上归属不明的进程。
2. 执行上述构建与模型下载命令。
3. 两个旧硬编码默认模型路径会一次性迁移到新 GGUF 默认路径；自定义路径保留，但旧 HF/MLX 目录不能直接交给新引擎，需要在设置中另选 GGUF。
4. 历史会议 JSON、端口和自定义纪要 Prompt 不受影响。旧模型和旧虚拟环境不会被自动删除，可在新版验证通过后自行清理。

## 当前边界

- ASR 每 1.5 秒识别一次当前完整缓冲，句末或 15 秒时落定；这是离线轮询，不是服务端增量流式识别。
- 不提供说话人分离或词级时间戳；片段时间戳由 Swift 采集时钟生成。
- LLM 上下文初始为 32768 token、单请求槽位；长会议继续使用既有 12000 字符 map-reduce。
- 原 TTS 未接入主流程，本次随旧 Python worker 一并移除。
