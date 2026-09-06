#!/bin/bash
# =============================================================================
# 在线获取并安装 nv-codec-headers (NVENC/CUVID 头文件, LGPL; 编译期只要头)
#
# 用法:  fetch-nvcodec.sh <sdk版本> <安装prefix>
#   例:   fetch-nvcodec.sh 12.1.14.1 /usr/local
#
# 说明:
#   - 从 github.com/FFmpeg/nv-codec-headers 下载标签 n<版本> 的源码包,
#     `make install` 把头装到 <prefix>/include/ffnvcodec, 并生成 ffnvcodec.pc。
#   - 运行期由 NVIDIA 驱动提供 libcuda/nvEncodeAPI (FFmpeg dlopen, 不进链接)。
# 环境变量:
#   DEPS_DIR  下载缓存目录 (默认 <仓库根>/.deps)
#   SUDO      prefix 不可写时的提权命令 (如 sudo); 未设置时自动探测
# =============================================================================
set -euo pipefail

VER="${1:?用法: fetch-nvcodec.sh <sdk版本> <prefix>  例如: fetch-nvcodec.sh 12.1.14.1 /usr/local}"
PREFIX="${2:?用法: fetch-nvcodec.sh <sdk版本> <prefix>}"
DEPS_DIR="${DEPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deps}"

# prefix 不可写时自动加 sudo (无 sudo 则原样失败, 由调用方环境保证)
SUDO="${SUDO:-}"
if [ ! -w "$PREFIX" ] && [ ! -w "$(dirname "$PREFIX")" ] && [ -z "$SUDO" ]; then
  command -v sudo >/dev/null 2>&1 && SUDO=sudo
fi
run_as() {
  if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi
}

TARBALL="$DEPS_DIR/nv-codec-headers-n$VER.tar.gz"
mkdir -p "$DEPS_DIR"
if [ ! -f "$TARBALL" ]; then
  echo "==> 在线获取 nv-codec-headers n$VER"
  curl -fL --retry 3 -o "$TARBALL" "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n$VER.tar.gz"
fi

SRC="$DEPS_DIR/nv-codec-headers-$VER"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1

echo "==> 安装 ffnvcodec -> $PREFIX"
run_as make -C "$SRC" install PREFIX="$PREFIX" >/dev/null
