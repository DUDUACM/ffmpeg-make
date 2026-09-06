#!/bin/bash
# =============================================================================
# 在线获取 Vulkan-Headers (Khronos 官方, 纯头文件)
#
# 用法:  fetch-vulkan.sh <版本>      例: fetch-vulkan.sh 1.4.359
#
# 说明:
#   - 从 github.com/KhronosGroup/Vulkan-Headers 下载标签 v<版本> 的源码包,
#     解压到 $DEPS_DIR/vulkan-headers-<版本>/ (含 include/vulkan + include/vk_video)。
#   - 各平台脚本自行把头拷进 sysroot/prefix 并生成 vulkan.pc / 导入库
#     (加载器运行期用系统/NDK 的 libvulkan, 头文件覆盖成新版即可)。
# 环境变量:
#   DEPS_DIR  下载缓存目录 (默认 <仓库根>/.deps)
# =============================================================================
set -euo pipefail

VER="${1:?用法: fetch-vulkan.sh <版本>  例如: fetch-vulkan.sh 1.4.359}"
DEPS_DIR="${DEPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deps}"

TARBALL="$DEPS_DIR/Vulkan-Headers-v$VER.tar.gz"
mkdir -p "$DEPS_DIR"
if [ ! -f "$TARBALL" ]; then
  echo "==> 在线获取 Vulkan-Headers v$VER"
  curl -fL --retry 3 -o "$TARBALL" "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$VER.tar.gz"
fi

DIR="$DEPS_DIR/vulkan-headers-$VER"
if [ ! -d "$DIR/include/vulkan" ]; then
  rm -rf "$DIR"
  mkdir -p "$DIR"
  tar -xzf "$TARBALL" -C "$DIR" --strip-components=1
fi

echo "==> Vulkan-Headers: $DIR"
