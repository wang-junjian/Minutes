#!/usr/bin/env bash
# 编译并运行真实原生 worker / EngineClient 闭环验证，不使用 XCTest 宿主。
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 请不要使用 sudo；原生引擎和模型按当前用户安装。" >&2
  echo "  请运行：sh scripts/verify_native.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="${TMPDIR:-/tmp}/minutes-native-worker-smoke"

swiftc -parse-as-library -O \
  "$ROOT/Minutes/Engine/EngineClient.swift" \
  "$ROOT/Minutes/Engine/OpenAIStreamParser.swift" \
  "$ROOT/Minutes/Engine/WAVEncoder.swift" \
  "$ROOT/Minutes/Engine/EngineConfiguration.swift" \
  "$ROOT/Minutes/Engine/EngineWorker.swift" \
  "$ROOT/Minutes/Engine/EngineHealth.swift" \
  "$ROOT/Minutes/Engine/ASRServerConfiguration.swift" \
  "$ROOT/Minutes/Meeting/MinutesComposer.swift" \
  "$ROOT/Minutes/Core/Models.swift" \
  "$ROOT/Benchmarks/NativeWorkerSmoke/main.swift" \
  -o "$BINARY"

"$BINARY"
