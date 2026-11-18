"""LLM worker：mlx-lm 加载 Qwen3.5-4B-OptiQ-4bit，NDJSON 流式输出。

接口：
  POST /v1/chat   body={"messages":[...], "temperature":0.3, "max_tokens":4096}
                  响应为 NDJSON 流：{"token": "..."} 若干行，最后一行 {"done": true, "text": "全文"}

mlx-lm 0.32 起采样参数不再直接传给 stream_generate，要用 sample_utils.make_sampler
构造采样器再传入 sampler=。依赖 mlx-lm>=0.32（OptiQ 混合精度量化从该版本完整支持）。
铁律：本进程绝不主动 import transformers —— 它让启动从 1 秒变成 60 秒以上。
"""
from __future__ import annotations

import json
import threading
import time
from typing import Any

from fastapi import Request
from fastapi.responses import StreamingResponse

from .worker_base import LazyLoader, create_app, model_path, resolve_snapshot_path, run

loaded = threading.Event()


def _load_model():
    from mlx_lm import load

    path = resolve_snapshot_path(model_path())
    print(f"[llm] loading {path}", flush=True)
    t0 = time.time()
    model, tokenizer = load(path)
    print(f"[llm] loaded in {time.time() - t0:.1f}s", flush=True)
    loaded.set()
    return model, tokenizer


model_loader = LazyLoader(_load_model)

app = create_app("llm", loaded, preload=lambda: model_loader.get())


@app.post("/v1/chat")
async def chat(request: Request) -> StreamingResponse:
    payload: dict[str, Any] = await request.json()
    messages = payload.get("messages", [])
    temperature = float(payload.get("temperature", 0.3))
    max_tokens = int(payload.get("max_tokens", 4096))

    def generate():
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        model, tokenizer = model_loader.get()
        prompt = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True,
            enable_thinking=False,   # 纪要任务不需要思考过程，省首 token 延迟
        )
        yield json.dumps({"token": "", "ready": True}) + "\n"
        full = ""
        t0 = time.time()
        for chunk in stream_generate(
            model, tokenizer, prompt,
            max_tokens=max_tokens,
            sampler=make_sampler(temp=temperature),
        ):
            text = chunk.text
            if text:
                full += text
                yield json.dumps({"token": text}) + "\n"
        elapsed = time.time() - t0
        print(f"[llm] {len(full)} chars in {elapsed:.1f}s", flush=True)
        yield json.dumps({"done": True, "text": full}) + "\n"

    return StreamingResponse(generate(), media_type="application/x-ndjson")


if __name__ == "__main__":
    run(app)
