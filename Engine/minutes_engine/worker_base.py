"""worker 公共骨架：环境读取、健康检查、uvicorn 启动。"""
from __future__ import annotations

import os
import threading
import time
from typing import Any

from fastapi import FastAPI
import uvicorn


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


def port() -> int:
    return int(env("MINUTES_PORT", "8797"))


def bind_host() -> str:
    return env("MINUTES_BIND_HOST", "127.0.0.1")


def model_path() -> str:
    return env("MINUTES_MODEL_PATH")


def resolve_snapshot_path(path: str) -> str:
    """允许传 HF hub 缓存根目录，自动解析 snapshots/ 下最新快照。"""
    import glob

    candidates = sorted(glob.glob(os.path.join(path, "snapshots", "*")))
    for candidate in candidates:
        if os.path.exists(os.path.join(candidate, "config.json")):
            return candidate
    return path


def create_app(name: str, model_loaded: threading.Event, preload=None) -> FastAPI:
    """preload：可选的模型预热函数。服务启动 1 秒后在后台线程加载，
    让 /health 的 model_loaded 真实反映加载进度，首个请求不必等加载。"""
    app = FastAPI(title=f"minutes-{name}", docs_url=None, openapi_url=None)
    started_at = time.time()

    if preload is not None:
        threading.Timer(1.0, preload).start()

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "worker": name,
            "uptime": round(time.time() - started_at, 1),
            "model_loaded": model_loaded.is_set(),
        }

    return app


def run(app: FastAPI) -> None:
    uvicorn.run(app, host=bind_host(), port=port(), log_level="info")


class LazyLoader:
    """线程安全的单例模型加载器。

    模型加载耗时长（几秒到几十秒），用锁保证只加载一次；
    首次请求触发加载，健康检查在此期间返回 model_loaded=false。
    """

    def __init__(self, load_fn):
        self._load_fn = load_fn
        self._instance = None
        self._error: str | None = None
        self._lock = threading.Lock()

    def get(self):
        if self._instance is not None:
            return self._instance
        if self._error is not None:
            raise RuntimeError(self._error)
        with self._lock:
            if self._instance is None and self._error is None:
                try:
                    self._instance = self._load_fn()
                except Exception as exc:  # noqa: BLE001 —— 错误要能被健康检查发现
                    self._error = f"{type(exc).__name__}: {exc}"
                    raise
        if self._instance is None:
            raise RuntimeError(self._error or "model load failed")
        return self._instance
