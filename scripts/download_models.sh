#!/usr/bin/env bash
# 并行分块下载固定修订的 GGUF；只用系统 curl/shasum，不依赖 Python 或 hf CLI。
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 请不要使用 sudo；模型会下载到当前用户的 ~/Library/Application Support/Minutes。" >&2
  echo "  请运行：sh scripts/download_models.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../Engine/dependencies.lock
source "$PROJECT_ROOT/Engine/dependencies.lock"

MODELS_ROOT="${MINUTES_MODELS_ROOT:-$HOME/Library/Application Support/Minutes/models}"
DOWNLOAD_JOBS="${MINUTES_DOWNLOAD_JOBS:-4}"
CHUNK_BYTES="${MINUTES_DOWNLOAD_CHUNK_BYTES:-67108864}" # 64 MiB
mkdir -p "$MODELS_ROOT"

file_size() { /usr/bin/stat -f '%z' "$1"; }
file_hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
discard_chunks() {
  local target="$1"
  rm -f "$target".chunk.* "$target".chunk.*.download "$target.assembling" "$target.chunk-layout"
}

# 供 xargs 启动的独立 Bash 调用。每个分块先写临时文件，成功后原子替换。
download_range() {
  local url="$1" output="$2" start="$3" end="$4"
  local expected=$((end - start + 1))
  if [ -f "$output" ] && [ "$(file_size "$output")" = "$expected" ]; then
    return 0
  fi
  local temporary="$output.download" status
  rm -f "$temporary"
  status="$(curl --http1.1 --fail --location --silent --show-error \
    --retry 5 --retry-all-errors --connect-timeout 20 \
    --range "$start-$end" --output "$temporary" --write-out '%{http_code}' "$url")"
  if [ "$status" != "206" ] || [ "$(file_size "$temporary")" != "$expected" ]; then
    echo "✗ 分块失败：$output（HTTP $status）" >&2
    return 1
  fi
  mv "$temporary" "$output"
  echo "✓ 分块 $start-$end"
}
export -f file_size download_range

run_chunk_jobs() {
  local url="$1" target="$2" total="$3"
  local start end index
  for ((start = 0, index = 0; start < total; start += CHUNK_BYTES, index += 1)); do
    end=$((start + CHUNK_BYTES - 1))
    if [ "$end" -ge "$total" ]; then end=$((total - 1)); fi
    printf '%s\0%s\0%s\0%s\0' \
      "$url" "$(printf '%s.chunk.%05d' "$target" "$index")" "$start" "$end"
  done | xargs -0 -P "$DOWNLOAD_JOBS" -n 4 /bin/bash -c \
    'set -euo pipefail; download_range "$@"' _
}

download_model() {
  local repo="$1" revision="$2" relative="$3" expected_hash="$4" expected_bytes="$5" mirror_url="$6"
  local target="$MODELS_ROOT/$relative"
  mkdir -p "$(dirname "$target")"
  if [ -z "$expected_hash" ] || [ -z "$expected_bytes" ]; then
    echo "✗ dependencies.lock 缺少 $relative 的 SHA256/字节数" >&2
    exit 1
  fi

  if [ -f "$target" ] && [ "$(file_size "$target")" = "$expected_bytes" ] && \
     [ "$(file_hash "$target")" = "$expected_hash" ]; then
    echo "✓ 已存在且校验通过：$relative"
    return 0
  fi
  if [ -f "$target" ]; then
    echo "✗ 现有模型未通过锁定校验：$target" >&2
    return 1
  fi

  # 兼容旧版单连接下载留下的完整 .part。
  if [ -f "$target.part" ] && [ "$(file_size "$target.part")" = "$expected_bytes" ] && \
     [ "$(file_hash "$target.part")" = "$expected_hash" ]; then
    mv "$target.part" "$target"
    echo "✓ 模型就绪：$target"
    return 0
  fi

  local layout="$target.chunk-layout"
  local layout_signature="$expected_bytes:$CHUNK_BYTES"
  if [ -f "$layout" ] && [ "$(<"$layout")" != "$layout_signature" ]; then
    echo "→ 分块布局已变化，清理旧分块"
    discard_chunks "$target"
  fi
  printf '%s\n' "$layout_signature" > "$layout"

  local urls=()
  if [ -n "$mirror_url" ]; then urls+=("$mirror_url"); fi
  if [ -n "${MINUTES_HF_ENDPOINT:-}" ]; then
    urls+=("$MINUTES_HF_ENDPOINT/$repo/resolve/$revision/$relative")
  else
    urls+=("https://hf-mirror.com/$repo/resolve/$revision/$relative")
    urls+=("https://huggingface.co/$repo/resolve/$revision/$relative")
  fi

  local url completed=0
  for url in "${urls[@]}"; do
    echo "→ 并行下载：$url"
    if run_chunk_jobs "$url" "$target" "$expected_bytes"; then
      completed=1
      break
    fi
    echo "→ 当前来源有失败分块，保留下载进度并尝试下一来源" >&2
  done
  if [ "$completed" != "1" ]; then
    echo "✗ 下载失败：$relative（分块已保留，可重试）" >&2
    return 1
  fi

  local assembled="$target.assembling"
  rm -f "$assembled"
  # 分块名使用零填充序号，通配符顺序即字节顺序。
  /bin/cat "$target".chunk.* > "$assembled"
  if [ "$(file_size "$assembled")" != "$expected_bytes" ]; then
    echo "✗ 拼接后字节数不匹配：$relative（已清理分块，可重试）" >&2
    discard_chunks "$target"
    return 1
  fi
  local actual_hash
  actual_hash="$(file_hash "$assembled")"
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "✗ SHA256 不匹配：$relative（已清理损坏分块，可重试）" >&2
    discard_chunks "$target"
    return 1
  fi
  mv "$assembled" "$target"
  rm -f "$target".chunk.* "$target".chunk.*.download "$target.part"
  echo "✓ 模型就绪：$target"
  echo "  bytes=$expected_bytes"
  echo "  sha256=$actual_hash"
}

download_model "$ASR_MODEL_REPOSITORY" "$ASR_MODEL_REVISION" "$ASR_MODEL_FILE" "$ASR_MODEL_SHA256" "$ASR_MODEL_BYTES" "$ASR_MODEL_DOWNLOAD_URL"
download_model "$LLM_MODEL_REPOSITORY" "$LLM_MODEL_REVISION" "$LLM_MODEL_FILE" "$LLM_MODEL_SHA256" "$LLM_MODEL_BYTES" "$LLM_MODEL_DOWNLOAD_URL"

echo "✅ 两个 GGUF 模型均已就绪：$MODELS_ROOT"
