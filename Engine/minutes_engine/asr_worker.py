"""ASR worker：Qwen3-ASR 实时转写。

接口：
  POST /v1/asr   body = 16 kHz 单声道 float32 PCM（小端）；返回 JSON。

qwen_asr 的 transcribe 只接受 文件路径 / URL / base64 / (ndarray, sr) 元组，
裸 ndarray 会被 normalize_audio_input 拒绝——务必传 (samples, 16000)。
"""
from __future__ import annotations

import threading
import time
from typing import Any

import numpy as np
from fastapi import Request
from fastapi.responses import JSONResponse

from .worker_base import LazyLoader, create_app, model_path, run

SAMPLE_RATE = 16000
loaded = threading.Event()


def _load_model():
    import torch
    from qwen_asr import Qwen3ASRModel

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float16 if device != "cpu" else torch.float32
    print(f"[asr] loading {model_path()} device={device} dtype={dtype}", flush=True)
    t0 = time.time()
    model = Qwen3ASRModel.from_pretrained(
        model_path(),
        dtype=dtype,
        device_map=device,
        max_inference_batch_size=1,
        max_new_tokens=512,
    )
    print(f"[asr] loaded in {time.time() - t0:.1f}s", flush=True)
    loaded.set()
    return model


model_loader = LazyLoader(_load_model)

app = create_app("asr", loaded, preload=lambda: model_loader.get())


@app.post("/v1/asr")
async def transcribe(request: Request) -> JSONResponse:
    raw = await request.body()
    print(f"[asr] request body {len(raw)} bytes", flush=True)
    if len(raw) < SAMPLE_RATE * 2:  # 不足 0.5 秒没什么可识别的
        return JSONResponse({"text": "", "language": None, "duration": 0.0})

    samples = np.frombuffer(raw, dtype=np.float32).copy()
    duration = len(samples) / SAMPLE_RATE

    model = model_loader.get()
    results = model.transcribe(audio=(samples, SAMPLE_RATE), language=None)
    text = results[0].text if results else ""
    language = results[0].language if results else None
    return JSONResponse({"text": text, "language": language, "duration": round(duration, 3)})


if __name__ == "__main__":
    run(app)
