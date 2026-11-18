#!/usr/bin/env bash
# 构建并安装固定版本的 audio.cpp / llama.cpp（Apple Silicon + Metal）。
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 请不要使用 sudo；原生引擎会安装到当前用户的 ~/Library/Application Support/Minutes。" >&2
  echo "  请运行：sh scripts/bootstrap.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../Engine/dependencies.lock
source "$PROJECT_ROOT/Engine/dependencies.lock"

ENGINE_ROOT="${MINUTES_ENGINE_ROOT:-$HOME/Library/Application Support/Minutes/engine}"
NATIVE_ROOT="$PROJECT_ROOT/Engine/.native"
JOBS="${MINUTES_BUILD_JOBS:-$(/usr/sbin/sysctl -n hw.ncpu)}"
MACOS_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

for tool in git cmake clang++ xcrun curl install otool codesign tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "✗ 缺少构建工具：$tool" >&2; exit 1; }
done
xcrun --find metal >/dev/null 2>&1 || { echo "✗ 未找到 Metal 编译器，请安装 Xcode" >&2; exit 1; }

mkdir -p "$NATIVE_ROOT/src" "$NATIVE_ROOT/build" "$ENGINE_ROOT/bin" "$ENGINE_ROOT/lib"

fetch_repo() {
  local name="$1" repository="$2" commit="$3"
  local directory="$NATIVE_ROOT/src/$name"
  if [ -d "$directory" ] && [ ! -d "$directory/.git" ] && [ -n "$(/bin/ls -A "$directory")" ]; then
    echo "✗ $directory 非空但不是 Git 源码目录" >&2
    exit 1
  fi
  mkdir -p "$directory"
  if [ ! -d "$directory/.git" ]; then
    git -C "$directory" init
    git -C "$directory" remote add origin "$repository"
  fi
  if [ -f "$directory/.minutes-source-commit" ] && [ "$(<"$directory/.minutes-source-commit")" = "$commit" ]; then
    echo "✓ $name 源码归档版本已固定"
    return 0
  fi
  local archive="$NATIVE_ROOT/archives/$name-$commit.tar.gz"
  if [ -s "$archive" ] && tar -tzf "$archive" >/dev/null 2>&1; then
    echo "✓ 使用已验证的 $name 源码归档"
    tar -xzf "$archive" -C "$directory" --strip-components 1
    printf '%s\n' "$commit" > "$directory/.minutes-source-commit"
    return 0
  fi
  if [ "$(git -C "$directory" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
    echo "→ 获取 $name@$commit"
    if git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
      -C "$directory" fetch --depth 1 origin "$commit"; then
      git -C "$directory" checkout --detach "$commit"
    else
      echo "→ Git 传输失败，改用同一提交的源码归档"
      archive="$NATIVE_ROOT/archives/$name-$commit.tar.gz"
      mkdir -p "$NATIVE_ROOT/archives"
      rm -f "$archive.download"
      # codeload 不支持 Range；完整下载并验证归档后才替换，避免误用半截文件。
      curl --http1.1 --fail --location --output "$archive.download" \
        "${repository%.git}/archive/$commit.tar.gz"
      [ -s "$archive.download" ] && tar -tzf "$archive.download" >/dev/null
      mv "$archive.download" "$archive"
      tar -xzf "$archive" -C "$directory" --strip-components 1
      printf '%s\n' "$commit" > "$directory/.minutes-source-commit"
    fi
  else
    echo "✓ $name 源码版本已固定"
  fi
}

fetch_repo audio.cpp "$AUDIOCPP_REPOSITORY" "$AUDIOCPP_COMMIT"
fetch_repo llama.cpp "$LLAMACPP_REPOSITORY" "$LLAMACPP_COMMIT"

# llama.cpp：只构建本机服务，模型由独立 Shell 脚本下载。
LLAMA_SOURCE="$NATIVE_ROOT/src/llama.cpp"
LLAMA_BUILD="$NATIVE_ROOT/build/llama.cpp"
echo "→ 配置 llama.cpp（Release / arm64 / Metal）"
cmake -S "$LLAMA_SOURCE" -B "$LLAMA_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_CCACHE=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF \
  -DLLAMA_BUILD_COMMIT="${LLAMACPP_COMMIT:0:7}" \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF
cmake --build "$LLAMA_BUILD" --config Release --target llama-server -j "$JOBS"

# audio.cpp：使用上游 Metal 部署脚本，确保 metallib 与后端资源正确处理。
AUDIO_SOURCE="$NATIVE_ROOT/src/audio.cpp"
echo "→ 构建 audio.cpp（Release / arm64 / Metal）"
"$AUDIO_SOURCE/scripts/build_metal.sh" --deployment-build --target audiocpp_server
AUDIO_BINARY="$AUDIO_SOURCE/build/macos-metal-release/bin/audiocpp_server"
LLAMA_BINARY="$LLAMA_BUILD/bin/llama-server"
[ -x "$AUDIO_BINARY" ] || { echo "✗ 未生成 $AUDIO_BINARY" >&2; exit 1; }
[ -x "$LLAMA_BINARY" ] || { echo "✗ 未生成 $LLAMA_BINARY" >&2; exit 1; }

install_binary() {
  local source="$1" name="$2"
  local temporary="$ENGINE_ROOT/bin/.$name.installing"
  install -m 755 "$source" "$temporary"
  mv "$temporary" "$ENGINE_ROOT/bin/$name"
  codesign --force --sign - "$ENGINE_ROOT/bin/$name" >/dev/null
}

install_binary "$AUDIO_BINARY" audiocpp_server
install_binary "$LLAMA_BINARY" llama-server

for binary in "$ENGINE_ROOT/bin/audiocpp_server" "$ENGINE_ROOT/bin/llama-server"; do
  echo "→ 检查动态依赖：$binary"
  if otool -L "$binary" | /usr/bin/grep -Ei 'Python\.framework|Torch|MLX|ffmpeg|/opt/homebrew|'"$NATIVE_ROOT" ; then
    echo "✗ 发现禁止的运行依赖：$binary" >&2
    exit 1
  fi
done

"$ENGINE_ROOT/bin/audiocpp_server" --version
"$ENGINE_ROOT/bin/llama-server" --version

echo ""
echo "✅ 原生引擎安装完成：$ENGINE_ROOT/bin"
echo "下一步：bash scripts/download_models.sh"
