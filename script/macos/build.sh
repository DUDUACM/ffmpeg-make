#!/bin/bash
# =============================================================================
# FFmpeg macOS 编译脚本 (原生编译; 在 macOS / GitHub macos runner 上执行)
#
# 用法:  build.sh <version> [arch ...]      arch: x86_64 | arm64
#   例:   build.sh 9.0                      # 构建 9.0 (当前机器架构)
#         build.sh 9.0 x86_64               # 在 Intel 机器/runner 上构建 x86_64
#
# 说明:
#   - 源码在线获取: github.com/FFmpeg/FFmpeg.git 按标签 n<版本> 浅克隆 (git 保留 +x)。
#   - 纯 LGPL (不开 --enable-gpl / --enable-version3, 禁用 postproc), 便于闭源动态链接。
#   - 硬件加速走 VideoToolbox (LGPL, 系统 framework, 无额外运行期依赖);
#     macOS 不用 VAAPI/Vulkan(MoltenVK)/NVENC。
#   - 输出: 静态库 .a + 合并的单一 libffmpeg.dylib + ffmpeg/ffprobe,
#     写到 build/ffmpeg-<版本>-macos-<架构>/。
# =============================================================================
set -euo pipefail

VER="${1:?用法: build.sh <version> [arch...]  例如: build.sh 9.0}"
shift || true

if [ "$#" -gt 0 ]; then
  ARCHES=("$@")
else
  ARCHES=("$(uname -m)")          # x86_64 / arm64
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="${SRC_ROOT:-$REPO_ROOT}"
DEPS_DIR="${DEPS_DIR:-$SRC_ROOT/.deps}"
OUT_BASE="${OUT_BASE:-$SRC_ROOT/build}"
PLATFORM="macos"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

bash "$REPO_ROOT/script/common/fetch-ffmpeg.sh" "$VER"
WORK="$DEPS_DIR/ffmpeg-$VER"

# 仅当该版本存在 postproc 选项时才禁用 (8.x/9.0 已移除该库)
POSTPROC_CFG=""
if grep -q 'postproc' "$WORK/configure"; then
  POSTPROC_CFG="--disable-postproc"
fi

# VideoToolbox: 选项与编码器按版本可用性启用
VT_CFG=""
if grep -q 'videotoolbox' "$WORK/configure"; then
  VT_CFG="--enable-videotoolbox"
fi
VT_ENC_CFG=""
for c in h264 hevc; do
  if grep -qE "${c}_videotoolbox_encoder_(deps|select)=" "$WORK/configure"; then
    VT_ENC_CFG+=" --enable-encoder=${c}_videotoolbox"
  fi
done

# 关闭自动检测 (runner 装了 XQuartz 等会被误启用, 且 X11 依赖不该进分发产物),
# 显式启用需要的系统库 (SDK 自带头文件)
EXTRA_LIB_CFG="--enable-zlib --enable-bzlib --enable-iconv"

build_one() {
  local ARCH="$1" CPU CPU_ARG OPTCFLAGS X86ASM_CFG
  local PREFIX="$OUT_BASE/ffmpeg-${VER}-${PLATFORM}-${ARCH}"

  case "$ARCH" in
    x86_64)
      CPU="x86-64"; CPU_ARG="--cpu=$CPU"; OPTCFLAGS="-march=x86-64"
      X86ASM_CFG="--enable-x86asm"          # 需要 nasm
      ;;
    arm64)
      CPU=""; CPU_ARG=""; OPTCFLAGS=""
      X86ASM_CFG="--disable-x86asm"
      ;;
    *)
      echo "错误: 未知架构 -> $ARCH (支持 x86_64 | arm64)"; exit 1 ;;
  esac

  echo "==> [$VER/macos-$ARCH] configure"
  cd "$WORK"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  ./configure \
    --prefix="$PREFIX" \
    --disable-debug \
    --enable-pic \
    --enable-stripping \
    --disable-autodetect \
    $EXTRA_LIB_CFG \
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
    $VT_CFG \
    $VT_ENC_CFG \
    --target-os=darwin \
    --arch="$ARCH" \
    $CPU_ARG \
    --cc=clang \
    --cxx=clang++ \
    --extra-cflags="-fPIC -O3 $OPTCFLAGS" \
    --extra-ldflags="-fPIC"

  echo "==> [$VER/macos-$ARCH] make -j${JOBS}"
  make clean
  make -j"$JOBS"
  make install

  # 从 config.mak 的 EXTRALIBS* 行提取系统依赖 (-l... / -framework ...), 合并 dylib 链接用
  local EXTRA_LINK
  EXTRA_LINK="$(grep -E '^EXTRALIBS' ffbuild/config.mak | grep -oE '\-l[A-Za-z0-9_]+|-framework +[A-Za-z]+' | sed 's/-framework  */-framework /' | sort -u | tr '\n' ' ' || true)"
  [ -z "$EXTRA_LINK" ] && EXTRA_LINK="-lm -lz -lbz2 -liconv -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox"

  echo "==> [$VER/macos-$ARCH] 合并静态库 -> libffmpeg.dylib  (extra=$EXTRA_LINK)"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  clang -dynamiclib -o "$PREFIX/libffmpeg.dylib" \
    -fPIC \
    -install_name @rpath/libffmpeg.dylib \
    -Wl,-headerpad_max_install_names \
    -Wl,-force_load,libavcodec/libavcodec.a \
    -Wl,-force_load,libavformat/libavformat.a \
    -Wl,-force_load,libswresample/libswresample.a \
    -Wl,-force_load,libavfilter/libavfilter.a \
    -Wl,-force_load,libavutil/libavutil.a \
    -Wl,-force_load,libswscale/libswscale.a \
    $EXTRA_LINK

  echo "==> [$VER/macos-$ARCH] 完成 -> $PREFIX"
}

for ARCH in "${ARCHES[@]}"; do
  build_one "$ARCH"
done

echo "==> [$VER/macos] 全部完成 (${ARCHES[*]})"
