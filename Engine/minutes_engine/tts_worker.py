"""TTS worker：VoxCPM2-8bit（MLX），按句流式输出 48 kHz float32 PCM。

接口：
  POST /v1/tts   body={"text": "...", "sample_rate": 48000}
                 响应体为持续的 application/octet-stream：float32 小端 PCM，
                 按句生成、按句下发（首句出来就发，不等全文）。

mlx-audio 0.6.x 没有导出的 generate() 顶层函数，正确入口是
mlx_audio.tts.utils.load_model() 拿到模型后调 model.generate(text=...)，
该方法是 GenerationResult 生成器，逐段吐出 audio（mx.array，48 kHz）。

说明：句级流水线拿到可听的低首包延迟；patch 级真流式可移植
voxcpm-studio/engines/mlx/voxcpm_stream.py（已验证与整段解码 SNR 116 dB）。
"""
from __future__ import annotations

import re
import threading
import time
from pathlib import Path
from typing import Any

import numpy as np
from fastapi import Request
from fastapi.responses import StreamingResponse

from .worker_base import LazyLoader, create_app, model_path, run

loaded = threading.Event()


def _load_model():
    from mlx_audio.tts.utils import load_model

    print(f"[tts] loading {model_path()}", flush=True)
    t0 = time.time()
    model = load_model(Path(model_path()))
    # 触发一次极小生成，把 Metal 内核编译掉，避免首个正式请求卡几秒。
    for result in model.generate(text="嗯。", inference_timesteps=10, cfg_value=2.0):
        _ = result.audio
    print(f"[tts] loaded+warm in {time.time() - t0:.1f}s", flush=True)
    loaded.set()
    return model


model_loader = LazyLoader(_load_model)

app = create_app("tts", loaded, preload=lambda: model_loader.get())

_SENTENCE_SPLIT = re.compile(r"(?<=[。！？!?.；;])\s*|(?<=\n)")


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in _SENTENCE_SPLIT.split(text) if s.strip()]


@app.post("/v1/tts")
async def tts(request: Request) -> StreamingResponse:
    payload: dict[str, Any] = await request.json()
    text = str(payload.get("text", "")).strip()
    if not text:
        return StreamingResponse(iter([]), media_type="application/octet-stream")

    def generate():
        model = model_loader.get()
        # 整段文本一次 generate：音色由同一次采样决定，按句分开合成会
        # 每句独立采样，音色忽男忽女（实测用户反馈）。
        t0 = time.time()
        for result in model.generate(
            text=text, inference_timesteps=10, cfg_value=2.0
        ):
            wav = np.asarray(result.audio, dtype=np.float32).reshape(-1)
            print(f"[tts] chunk: {len(wav) / result.sample_rate:.2f}s "
                  f"audio / {time.time() - t0:.2f}s", flush=True)
            yield wav.tobytes()

    return StreamingResponse(generate(), media_type="application/octet-stream")


if __name__ == "__main__":
    run(app)
