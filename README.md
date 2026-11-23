# Minutes

macOS 原生智能会议纪要应用。全程本地推理，不上传任何音频与文本。

- **ASR**：[Qwen3-ASR-0.6B](https://github.com/QwenLM/Qwen3-ASR)（PyTorch / MPS）
- **LLM**：[Qwen3.5-4B-OptiQ-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit)（MLX 混合精度量化）
- **TTS**：VoxCPM2-8bit（[mlx-audio](https://github.com/Blaizzy/mlx-audio)）

## 架构

```
┌────────────────────────── macOS App（SwiftUI / Swift 6）──────────────────────────┐
│  Views ← MeetingSession ← AudioCapture + VAD            EngineSupervisor          │
│     ↑            ↓ async stream                          ↓ 进程管理/健康检查       │
│  MeetingsStore(JSON 落盘)   EngineClient(actor, NDJSON/字节流)                     │
└──────────┬───────────────────────┬───────────────────────┬────────────────────────┘
           │ 127.0.0.1:8787        │ 127.0.0.1:8788        │ 127.0.0.1:8789
┌──────────▼─────────┐  ┌──────────▼─────────┐  ┌──────────▼─────────┐
│ asr_worker         │  │ llm_worker         │  │ tts_worker         │
│ .venvs/asr (torch) │  │ .venvs/llm (mlx)   │  │ .venvs/tts (mlx)   │
└────────────────────┘  └────────────────────┘  └────────────────────┘
```

设计原则：

1. **分进程分环境**。torch 与 mlx 的底层加速库互相拖累（实测见
   `voxcpm-studio/engines/mlx/requirements.txt` 的注释），三个 worker
   各自独立 venv、独立进程，崩溃互不影响。
2. **纯函数边界**。VAD 是纯协议（`VADEngine`），提示词构造与解析是纯函数
   （`MinutesComposer`），采集器不持有会议状态。每个模块可单独替换、单独测试。
3. **状态机显式化**。会议只有 `idle / live / paused / composing / completed`
   五个相位，迁移路径在 `MeetingSession` 里一眼看全。
4. **乱序归位**。ASR 各语句识别耗时不同，响应按 `sequence` 归位，转写永不串行。

## 快速开始

```bash
# 1. 初始化推理引擎（创建三个 venv，约 10 GB 依赖）
./scripts/bootstrap.sh

# 2. 打开工程（Xcode 16+）
open Minutes.xcodeproj

# 3. 首次运行前：系统设置 → 隐私与安全性 → 麦克风，允许 Minutes
# 4. 应用内「设置」→「全部启动」，三个状态灯变绿后点工具栏「新会议」
```

模型路径在「设置」中配置，默认值已指向本机实际位置（qwenasr-studio /
HF hub 缓存 / voxcpm-studio）。LLM 路径支持直接传 hub 缓存根目录，
worker 会自动解析 `snapshots/` 下最新快照。

## 引擎接口

三个 worker 均为 FastAPI，约定一致：

| 端点 | 说明 |
|-|-|
| `GET /health` | `{"status":"ok","model_loaded":bool}`，Swift 端健康检查 |
| `POST /v1/asr` | body 为 16 kHz float32 PCM → `{"text","language","duration"}` |
| `POST /v1/chat` | `{"messages":[...]}` → NDJSON 流，`{"token":...}` × N + `{"done":true,"text":...}` |
| `POST /v1/tts` | `{"text":...}` → `application/octet-stream`，48 kHz float32 PCM 按句流式下发 |

手动调试某个 worker：

```bash
MINUTES_PORT=8787 MINUTES_MODEL_PATH=... \
  .venvs/asr/bin/python -m minutes_engine.asr_worker
```

## 目录

```
Minutes/
├── Minutes.xcodeproj/        # Xcode 16+ 工程（同步目录分组）
├── Minutes/                  # Swift 源码
│   ├── Core/                 # 数据模型、日志
│   ├── Engine/               # worker 进程管理 + 流式客户端
│   ├── Audio/                # 采集（16 kHz 统一重采样）、VAD、TTS 播放
│   ├── Meeting/              # 会议状态机、纪要提示词、JSON 持久化
│   └── Views/                # SwiftUI
├── Engine/
│   ├── minutes_engine/       # asr / llm / tts 三个 worker + 公共骨架
│   └── requirements/         # 每个 worker 一份，互不污染
└── scripts/bootstrap.sh      # 一键初始化三个 venv
```

## 已知边界与下一步

- TTS 目前是**句级**流式（首包快，但不是 patch 级）。patch 级真流式实现可直接
  移植 `voxcpm-studio/engines/mlx/voxcpm_stream.py`（已验证与整段解码 SNR 116 dB）。
- ASR 按语句整段识别（VAD 切句），尚无中间结果（partial）显示；Qwen3-ASR
  的流式能力具备后可在 `asr_worker` 加 `/v1/asr/stream`。
- VAD 是能量门限；会议远场拾音可换 Silero VAD，实现 `VADEngine` 协议即可。
- 说话人分离（diarization）未包含，Qwen3-ASR 系列具备该能力后可接入。
