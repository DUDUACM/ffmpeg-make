#!/bin/bash
# =============================================================================
# FFmpeg Linux(Ubuntu) 编译脚本 (原生编译; 在 Linux / GitHub ubuntu runner 上执行)
#
# 用法:  build.sh <version> [arch ...]      arch: x86_64 | arm64
#   例:   build.sh 9.0                      # 构建 9.0 (当前机器架构)
#
# 说明:
#   - 源码在线获取: github.com/FFmpeg/FFmpeg.git 按标签 n<版本> 浅克隆 (git 保留 +x)。
#   - 纯 LGPL (不开 --enable-gpl / --enable-version3, 禁用 postproc), 便于闭源动态链接。
#   - x86_64 与 arm64 均开启 VAAPI + NVENC/CUVID (NVIDIA) + Vulkan 硬件加速 (LGPL);
#     运行期需 libva2 + libvulkan1 + 显卡驱动 (NVENC/CUVID 实际使用时还需 NVIDIA
#     专有驱动提供 libcuda.so.1, 由 FFmpeg 运行期 dlopen, 不进链接)。
#   - Vulkan 头用 Khronos 在线包 (默认 1.4.x) 覆盖系统旧头 (系统 1.3.275 不够
#     FFmpeg 7.1.5+ 的 >=1.3.277 要求), 运行期仍链接系统 libvulkan 加载器。
#   - 输出: 静态库 .a + 合并的单一 libffmpeg.so + ffmpeg/ffprobe,
#     写到 build/ffmpeg-<版本>-linux-<架构>/。
# =============================================================================
set -euo pipefail

VER="${1:?用法: build.sh <version> [arch...]  例如: build.sh 9.0}"
shift || true

if [ "$#" -gt 0 ]; then
  ARCHES=("$@")
else
  ARCHES=("$(uname -m)")          # x86_64 / aarch64
fi
ARCHES=("${ARCHES[@]/aarch64/arm64}")   # 统一架构名

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="${SRC_ROOT:-$REPO_ROOT}"
DEPS_DIR="${DEPS_DIR:-$SRC_ROOT/.deps}"
OUT_BASE="${OUT_BASE:-$SRC_ROOT/build}"
PLATFORM="linux"
JOBS="${JOBS:-$(nproc)}"

# /usr/local 不可写时自动加 sudo (CI runner 用户非 root)
SUDO="${SUDO:-}"
if [ ! -w /usr/local ] && [ -z "$SUDO" ]; then
  command -v sudo >/dev/null 2>&1 && SUDO=sudo
fi
run_as() {
  if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi
}

bash "$REPO_ROOT/script/common/fetch-ffmpeg.sh" "$VER"
WORK="$DEPS_DIR/ffmpeg-$VER"

# 仅当该版本存在 postproc 选项时才禁用 (8.x/9.0 已移除该库)
POSTPROC_CFG=""
if grep -q 'postproc' "$WORK/configure"; then
  POSTPROC_CFG="--disable-postproc"
fi

# VAAPI 硬件编码器: 按版本可用性启用 (老版本可能没有 av1_vaapi 等)
VAAPI_ENC_CFG=""
for c in h264 hevc mjpeg mpeg2 vp8 vp9 av1; do
  if grep -qE "${c}_vaapi_encoder_(deps|select)=" "$WORK/configure"; then
    VAAPI_ENC_CFG+=" --enable-encoder=${c}_vaapi"
  fi
done

# Vulkan: 用 Khronos 在线头覆盖系统 vulkan 头 (系统 1.3.275 太旧), 生成 vulkan.pc 覆盖版本
VK_VER="${VK_HEADERS_VER:-1.4.359}"
bash "$REPO_ROOT/script/common/fetch-vulkan.sh" "$VK_VER"
VKH="$DEPS_DIR/vulkan-headers-$VK_VER"
echo "==> [$VER] 覆盖 vulkan 头 -> /usr/local/include (v$VK_VER)"
run_as mkdir -p /usr/local/include/vulkan /usr/local/include/vk_video
run_as cp -a "$VKH/include/vulkan/." /usr/local/include/vulkan/
run_as cp -a "$VKH/include/vk_video/." /usr/local/include/vk_video/
VK_PC_DIR="/tmp/vkpc"
mkdir -p "$VK_PC_DIR"
printf 'Name: Vulkan\nDescription: Vulkan\nVersion: %s\nLibs: -lvulkan\nCflags: -I/usr/local/include\n' "$VK_VER" > "$VK_PC_DIR/vulkan.pc"
export PKG_CONFIG_PATH="$VK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
VULKAN_CFG="--enable-vulkan"
VULKAN_LINK="-lvulkan"

# ffnvcodec 头 (NVENC/CUVID 硬件编解码, LGPL; FFmpeg 自动检测启用, 版本不兼容则静默跳过)
# 按 FFmpeg 版本选"能用的最新" ffnvcodec (各版本可接受范围不同), 装到 /usr/local 供 pkg-config 发现
case "$VER" in
  4.*) _nvcode_ver="9.1.23.3" ;;      # 4.4.x: 8/9.x, 更新 API 不兼容
  5.*) _nvcode_ver="11.1.5.4" ;;      # 5.1.x: 实测 11.x 兼容
  6.*|7.*) _nvcode_ver="12.1.14.1" ;; # 6.1/7.1: 首选范围 >=12.1.14.0
  *)   _nvcode_ver="13.1.15.0" ;;     # 8.x/9.0: 最新
esac
SUDO="$SUDO" bash "$REPO_ROOT/script/common/fetch-nvcodec.sh" "$_nvcode_ver" /usr/local
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"   # ffnvcodec.pc 装在这里

build_one() {
  local ARCH="$1" CC CXX CPU CPU_ARG OPTCFLAGS X86ASM_CFG VAAPI_CFG EXTRA_LINK
  local PREFIX="$OUT_BASE/ffmpeg-${VER}-${PLATFORM}-${ARCH}"

  case "$ARCH" in
    x86_64)
      CC=gcc; CXX=g++
      CPU="x86-64"; CPU_ARG="--cpu=$CPU"; OPTCFLAGS="-march=x86-64"
      X86ASM_CFG="--enable-x86asm"                      # 需要 nasm
      VAAPI_CFG="--enable-vaapi"                        # Intel/AMD 硬件解码 (LGPL)
      EXTRA_LINK="$(pkg-config --libs libva libdrm 2>/dev/null || echo '-lva -ldrm') $VULKAN_LINK"
      ;;
    arm64)
      CC=gcc; CXX=g++
      CPU="armv8-a"; CPU_ARG="--cpu=$CPU"; OPTCFLAGS=""
      X86ASM_CFG="--disable-x86asm"
      VAAPI_CFG="--enable-vaapi"                        # arm64 也有 libva (如 RK/Jetson 平台)
      EXTRA_LINK="$(pkg-config --libs libva libdrm 2>/dev/null || echo '-lva -ldrm') $VULKAN_LINK"
      ;;
    *)
      echo "错误: 未知架构 -> $ARCH (支持 x86_64 | arm64)"; exit 1 ;;
  esac

  echo "==> [$VER/linux-$ARCH] configure"
  cd "$WORK"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  ./configure \
    --prefix="$PREFIX" \
    --disable-debug \
    --enable-pic \
    --enable-stripping \
    $POSTPROC_CFG \
    --enable-small \
    --enable-static \
    --disable-shared \
    --disable-doc \
    --disable-programs \
    --enable-ffmpeg \
    --disable-ffplay \
    --enable-ffprobe \
    --disable-avdevice \
    --disable-symver \
    --enable-asm \
    $X86ASM_CFG \
    --enable-hwaccels \
    $VAAPI_CFG \
    $VAAPI_ENC_CFG \
    $VULKAN_CFG \
    --target-os=linux \
    --arch="$ARCH" \
    $CPU_ARG \
    --cc="$CC" \
    --cxx="$CXX" \
    --extra-cflags="-fPIC -O3 $OPTCFLAGS" \
    --extra-ldflags="-fPIC"

  echo "==> [$VER/linux-$ARCH] make -j${JOBS}"
  make clean
  make -j"$JOBS"
  make install

  echo "==> [$VER/linux-$ARCH] 合并静态库 -> libffmpeg.so"
  printf '{ global: *; };\n' > /tmp/ffmpeg.ver
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  "$CC" -shared -o "$PREFIX/libffmpeg.so" \
    -fPIC -Wl,-Bsymbolic \
    -Wl,--version-script=/tmp/ffmpeg.ver \
    -Wl,--whole-archive \
    libavcodec/libavcodec.a \
    libavformat/libavformat.a \
    libswresample/libswresample.a \
    libavfilter/libavfilter.a \
    libavutil/libavutil.a \
    libswscale/libswscale.a \
    -Wl,--no-whole-archive \
    -Wl,--allow-multiple-definition \
    -lm -lz -ldl -lpthread $EXTRA_LINK

  echo "==> [$VER/linux-$ARCH] 完成 -> $PREFIX (VAAPI=$VAAPI_CFG extra=$EXTRA_LINK)"
}

for ARCH in "${ARCHES[@]}"; do
  build_one "$ARCH"
done

echo "==> [$VER/linux] 全部完成 (${ARCHES[*]})"
