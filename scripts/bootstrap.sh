#!/usr/bin/env bash
# 初始化 Minutes 推理引擎：两个独立 venv（分进程分环境，torch 与 mlx 不混装）。
#
# 加速策略（相比初版 pip 串行安装，通常从 30 分钟降到 3 分钟以内）：
#   1. 用 uv 并发下载；默认走清华镜像，可用 PIP_INDEX_URL 覆盖；
#   2. ASR 的 torch/transformers 直接复用 voxcpm-studio 的现成 venv（.pth 链接，
#      约 800 MB 免下载）。仍是独立进程，隔离原则不破；
#      用 MINUTES_ASR_REUSE="" 可强制全新安装。
#
# 用法：
#   scripts/bootstrap.sh
set -euo pipefail

INDEX="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
ENGINE_ROOT="${MINUTES_ENGINE_ROOT:-$HOME/Library/Application Support/Minutes/engine}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="python3.12"
UV="$(command -v uv || true)"

echo "→ 引擎目录：$ENGINE_ROOT"
echo "→ 包索引：$INDEX"
[ -n "$UV" ] && echo "→ 安装器：uv $("$UV" --version | awk '{print $2}')" || echo "→ 安装器：pip（建议 brew install uv）"
mkdir -p "$ENGINE_ROOT"

# 1. 拷贝引擎代码（幂等）
if [ "$PROJECT_ROOT/Engine" -ef "$ENGINE_ROOT" ]; then
  echo "→ 引擎目录即工程目录，跳过拷贝"
else
  rsync -a --delete "$PROJECT_ROOT/Engine/minutes_engine" "$ENGINE_ROOT/"
  rsync -a "$PROJECT_ROOT/Engine/requirements/" "$ENGINE_ROOT/requirements/"
fi

create_venv() {
  local venv="$1"
  if [ ! -x "$venv/bin/python" ]; then
    echo "→ 创建 venv: $venv"
    if [ -n "$UV" ]; then
      "$UV" venv --python "$PY" "$venv"
    else
      "$PY" -m venv "$venv"
    fi
  fi
}

install() { # install <venv> <packages...>
  local venv="$1"; shift
  if [ -n "$UV" ]; then
    UV_HTTP_TIMEOUT=60 "$UV" pip install --python "$venv/bin/python" --index-url "$INDEX" "$@"
  else
    "$venv/bin/pip" install -i "$INDEX" "$@"
  fi
}

# ---------------------------------------------------------------- ASR ----
ASR_VENV="$ENGINE_ROOT/.venvs/asr"
create_venv "$ASR_VENV"
ASR_SITE="$("$ASR_VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')"

REUSE="${MINUTES_ASR_REUSE-$HOME/GitHub/wang-junjian/voxcpm-studio/.venv}"
REUSE_SP="$(ls -d "$REUSE"/lib/python3.12/site-packages 2>/dev/null || true)"

if [ -n "$REUSE_SP" ] && [ -d "$REUSE_SP/torch" ]; then
  echo "→ ASR 复用 torch: $REUSE_SP（.pth 链接，免下载约 800 MB）"
  echo "$REUSE_SP" > "$ASR_SITE/reuse-voxcpm.pth"
  install "$ASR_VENV" qwen-asr --no-deps fastapi uvicorn soundfile python-multipart
  # --no-deps 后按 ImportError 逐个补齐缺失依赖（最多 8 轮）
  for i in $(seq 1 8); do
    if "$ASR_VENV/bin/python" -c 'import qwen_asr' 2>/tmp/minutes_importerr; then
      echo "→ ASR 依赖就绪"
      break
    fi
    mod="$(sed -n "s/No module named '\([^.']*\).*/\1/p" /tmp/minutes_importerr | head -1)"
    if [ -z "$mod" ]; then cat /tmp/minutes_importerr; echo "✗ ASR 依赖解析失败"; exit 1; fi
    echo "→ 补齐缺失依赖: $mod"
    install "$ASR_VENV" "$mod"
  done
else
  echo "→ 未找到可复用的 torch，全新安装（较慢）"
  install "$ASR_VENV" -r "$ENGINE_ROOT/requirements/asr.txt"
fi

# ---------------------------------------------------------------- LLM ----
LLM_VENV="$ENGINE_ROOT/.venvs/llm"
create_venv "$LLM_VENV"
echo "→ 安装 llm 依赖（mlx-lm>=0.32，OptiQ 混合精度支持）"
install "$LLM_VENV" "mlx-lm>=0.32" fastapi uvicorn

# ---------------------------------------------------------------- 验证 ----
echo ""
echo "→ 验证两个 venv 的关键依赖"
"$ASR_VENV/bin/python" -c 'import qwen_asr, torch, fastapi; print(f"asr   ok  torch={torch.__version__} mps={torch.backends.mps.is_available()}")'
"$LLM_VENV/bin/python" -c 'import mlx_lm, mlx.core as mx; print(f"llm   ok  mlx={mx.__version__} mlx_lm={mlx_lm.__version__}")'

echo ""
echo "✅ 全部完成。应用「设置」中的引擎目录应为："
echo "   $ENGINE_ROOT"
