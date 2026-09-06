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
# 显式启用需要的系统库 (SDK 自带头文件)。
# iconv: 新 SDK 里 iconv 不在 libSystem, configure 的 libc_iconv 检查不带 -liconv
# 且失败不禁用特性 -> 编译期启用/链接期缺符号; 显式加 --extra-ldflags=-liconv 解决。
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
    --extra-ldflags="-fPIC -liconv"

  echo "==> [$VER/macos-$ARCH] make -j${JOBS}"
  make clean
  make -j"$JOBS"
  make install

  # 从 config.mak 的 EXTRALIBS* 行提取系统依赖 (-l... / -framework ...), 合并 dylib 链接用
  local EXTRA_LINK
  EXTRA_LINK="$(grep -E '^EXTRALIBS' ffbuild/config.mak | grep -oE '\-l[A-Za-z0-9_]+|-framework +[A-Za-z]+' | sed 's/-framework  */-framework /' | sort -u | tr '\n' ' ' || true)"
  [ -z "$EXTRA_LINK" ] && EXTRA_LINK="-lm -lz -lbz2 -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox"
  EXTRA_LINK="$EXTRA_LINK -liconv"   # extra-ldflags 不进 EXTRALIBS, 合并 dylib 显式补

  echo "==> [$VER/macos-$ARCH] 合并静态库 -> libffmpeg.dylib  (extra=$EXTRA_LINK)"
  EXTRA_LINK="$EXTRA_LINK -liconv"   # extra-ldflags 不进 EXTRALIBS, 合并 dylib 显式补
  # ld64 没有 --allow-multiple-definition (旧 -multiply_defined 已成空操作), 而 FFmpeg
  # 内部有跨库重复源文件 (framepool.c 同时在 swscale 与 avfilter, force_load 全量加载
  # 会撞重复符号)。做法: 解包全部 .a, 丢弃"所有全局符号都被更早的库定义过"的目标
  # 文件 (等价 GNU ld 的先到先得), 再直接链接幸存目标文件。
  local stage="/tmp/ff-merge-$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  local libs=(libavcodec libavformat libswresample libavfilter libavutil libswscale)
  local lib obj
  for lib in "${libs[@]}"; do
    mkdir -p "$stage/$lib"
    (cd "$stage/$lib" && ar x "$WORK/$lib/lib$lib.a")
  done
  for lib in "${libs[@]}"; do
    for obj in "$stage/$lib"/*.o; do
      nm -gU "$obj" | awk -v o="$obj" '{print $NF, o}'
    done
  done > "$stage/syms.txt"
  awk '{ sym=$1; obj=$2; total[obj]++; if (!(sym in owner)) { owner[sym]=obj; unique[obj]++ } }
       END { for (o in total) if (unique[o]==0) print o }' "$stage/syms.txt" > "$stage/drop.txt"
  local dropped
  dropped="$(wc -l < "$stage/drop.txt" | tr -d ' ')"
  while IFS= read -r o; do rm -f "$o"; done < "$stage/drop.txt"
  echo "    去重丢弃目标文件: $dropped 个"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  clang -dynamiclib -o "$PREFIX/libffmpeg.dylib" \
    -fPIC \
    -install_name @rpath/libffmpeg.dylib \
    -Wl,-headerpad_max_install_names \
    "$stage"/*/*.o \
    $EXTRA_LINK
  rm -rf "$stage"

  echo "==> [$VER/macos-$ARCH] 完成 -> $PREFIX"
}

for ARCH in "${ARCHES[@]}"; do
  build_one "$ARCH"
done

echo "==> [$VER/macos] 全部完成 (${ARCHES[*]})"
