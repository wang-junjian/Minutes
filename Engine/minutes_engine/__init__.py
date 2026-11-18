"""Minutes 本地推理引擎。

三个 worker（asr / llm / tts）各自跑在独立进程、独立 venv 中：
torch 与 mlx 的底层 BLAS/加速库互相拖累，混在一个进程里谁都不快
（这一点在 voxcpm-studio 的 engines/mlx/requirements.txt 里有实测记录）。

共同约定：
  - 环境变量 MINUTES_PORT / MINUTES_BIND_HOST / MINUTES_MODEL_PATH 由 Swift 端注入；
  - 所有 worker 都提供 GET /health，Swift 端用它做健康检查；
  - 推理库一律延迟导入（lazy import），FastAPI 进程先起来再慢慢加载模型，
    健康检查才能区分「在加载」和「起不来」。
"""

__version__ = "0.1.0"
