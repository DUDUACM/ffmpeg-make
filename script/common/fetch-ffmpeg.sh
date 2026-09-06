#!/bin/bash
# =============================================================================
# 在线获取 FFmpeg 源码 (github.com/FFmpeg/FFmpeg.git, 按标签 n<版本> 浅克隆)
#
# 用法:  fetch-ffmpeg.sh <version>      例: fetch-ffmpeg.sh 9.0
#
# 说明:
#   - git 克隆保留可执行位 (configure 自带 +x), 无需额外 chmod。
#   - 源码落在 $DEPS_DIR/ffmpeg-<版本>/ (默认 <仓库根>/.deps), 已存在则复用。
# 环境变量:
#   DEPS_DIR  下载缓存目录 (默认 <仓库根>/.deps)
# =============================================================================
set -euo pipefail

VER="${1:?用法: fetch-ffmpeg.sh <version>  例如: fetch-ffmpeg.sh 9.0}"
DEPS_DIR="${DEPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deps}"
SRC="$DEPS_DIR/ffmpeg-$VER"

mkdir -p "$DEPS_DIR"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  echo "==> 在线获取 FFmpeg n$VER (https://github.com/FFmpeg/FFmpeg.git)"
  git clone --depth 1 --branch "n$VER" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

echo "==> FFmpeg 源码: $SRC"
