#!/bin/bash
# =============================================================================
# FFmpeg Android 交叉编译脚本 (在 Linux / GitHub ubuntu runner 上执行)
#
# 用法:  build.sh <version> [abi ...]
#   例:   build.sh 6.1.6                 # 构建 6.1.6 的全部 3 个 ABI
#         build.sh 9.0 arm64-v8a         # 只构建 9.0 的 arm64-v8a
#
# 说明:
#   - 源码在线获取: github.com/FFmpeg/FFmpeg.git 按标签 n<版本> 浅克隆 (git 保留 +x)。
#   - NDK 在线下载 (默认 r27d, 缓存在 $DEPS_DIR); API 28。
#   - 静态库 + 合并 libffmpeg.so, mediacodec 硬解 + Vulkan,
#     纯 LGPL (不开 --enable-gpl / --enable-version3, 禁用 postproc), 便于闭源动态链接。
#   - 自动适配版本差异: 8.x/9.0 已移除 postproc, 此处不再传 --disable-postproc。
#   - 输出写到 build/ffmpeg-<版本>-android-<ABI>/。
# =============================================================================
set -euo pipefail

VER="${1:?用法: build.sh <version> [abi...]  例如: build.sh 6.1.6}"
shift || true

if [ "$#" -gt 0 ]; then
  ABIS=("$@")
else
  ABIS=(arm64-v8a armeabi-v7a x86_64)
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="${SRC_ROOT:-$REPO_ROOT}"
DEPS_DIR="${DEPS_DIR:-$SRC_ROOT/.deps}"
OUT_BASE="${OUT_BASE:-$SRC_ROOT/build}"
PLATFORM="android"

NDK_VERSION="${NDK_VERSION:-r27d}"
NDK="${NDK:-$DEPS_DIR/android-ndk}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API="${API:-28}"
JOBS="${JOBS:-$(nproc)}"

STRIP="$TOOLCHAIN/bin/llvm-strip"
NM="$TOOLCHAIN/bin/llvm-nm"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"

# NDK 在线下载 (缺省时)
if [ ! -d "$NDK" ]; then
  echo "==> 在线获取 Android NDK $NDK_VERSION"
  mkdir -p "$DEPS_DIR"
  curl -fL --retry 3 -o "$DEPS_DIR/ndk.zip" "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
  unzip -q "$DEPS_DIR/ndk.zip" -d "$DEPS_DIR"
  mv "$DEPS_DIR/android-ndk-${NDK_VERSION}" "$NDK"
  rm -f "$DEPS_DIR/ndk.zip"
fi

bash "$REPO_ROOT/script/common/fetch-ffmpeg.sh" "$VER"
WORK="$DEPS_DIR/ffmpeg-$VER"

# 仅当该版本存在 postproc 选项时才禁用 (8.x/9.0 已移除该库, 传了会报未知选项)
POSTPROC_CFG=""
if grep -q 'postproc' "$WORK/configure"; then
  POSTPROC_CFG="--disable-postproc"
fi

# mediacodec 编码器 + av1 解码: 按版本可用性启用 (老版本可能没有这些)
MC_CODEC_CFG=""
for c in decoder:h264_mediacodec decoder:hevc_mediacodec decoder:vp8_mediacodec decoder:vp9_mediacodec decoder:mpeg4_mediacodec decoder:av1_mediacodec encoder:h264_mediacodec encoder:hevc_mediacodec encoder:av1_mediacodec; do
  kind="${c%%:*}"; name="${c#*:}"
  if grep -qE "${name}_${kind}_(deps|select)=" "$WORK/configure"; then
    MC_CODEC_CFG+=" --enable-${kind}=${name}"
  fi
done

# vulkan: Khronos 在线头 (默认 1.4.x) 覆盖 NDK sysroot 的旧头 (NDK 自带 1.3.275 不够新),
# 生成 vulkan.pc 让 pkg-config 检测 (android 用 --pkg-config=pkg-config)
VULKAN_CFG=""
VULKAN_LINK=""
VK_PC_DIR="/tmp/ffpc"
mkdir -p "$VK_PC_DIR"
export PKG_CONFIG_LIBDIR="$VK_PC_DIR"   # 只暴露 vulkan.pc, 其余库行为同 --pkg-config=false
VK_INC="$TOOLCHAIN/sysroot/usr/include/vulkan"
VK_VER="${VK_HEADERS_VER:-1.4.359}"
bash "$REPO_ROOT/script/common/fetch-vulkan.sh" "$VK_VER"
VKH="$DEPS_DIR/vulkan-headers-$VK_VER"
echo "==> [$VER] 覆盖 vulkan 头 -> NDK sysroot (v$VK_VER)"
mkdir -p "$VK_INC" "${VK_INC%/vulkan}/vk_video"   # vulkan_core.h 会 #include vk_video/...
cp -a "$VKH/include/vulkan/." "$VK_INC/"
cp -a "$VKH/include/vk_video/." "${VK_INC%/vulkan}/vk_video/"
printf 'Name: Vulkan\nDescription: Vulkan\nVersion: %s\nLibs: -lvulkan\n' "$VK_VER" > "$VK_PC_DIR/vulkan.pc"
VK_REQ="$(grep -oE 'vulkan >= [0-9.]+' "$WORK/configure" | head -1 | grep -oE '[0-9.]+' || true)"
if [ -z "$VK_REQ" ] || pkg-config --atleast-version="$VK_REQ" vulkan 2>/dev/null; then
  VULKAN_CFG="--enable-vulkan"; VULKAN_LINK="-lvulkan"
  echo "==> [$VER] vulkan 启用 ($VK_VER >= 要求 ${VK_REQ:-无})"
else
  echo "==> [$VER] vulkan 跳过 ($VK_VER < 要求 $VK_REQ)"
fi

build_one() {
  local ABI="$1" ARCH CPU CC CXX CROSS_PREFIX PREFIX CFLAGS LDFLAGS="" X86ASM_CFG
  PREFIX="$OUT_BASE/ffmpeg-${VER}-${PLATFORM}-${ABI}"

  case "$ABI" in
    arm64-v8a)
      ARCH=arm64; CPU=armv8-a
      CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
      CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
      CROSS_PREFIX="$TOOLCHAIN/bin/aarch64-linux-android-"
      CFLAGS="-march=$CPU"
      ;;
    armeabi-v7a)
      ARCH=arm; CPU=armv7-a
      CC="$TOOLCHAIN/bin/armv7a-linux-androideabi${API}-clang"
      CXX="$TOOLCHAIN/bin/armv7a-linux-androideabi${API}-clang++"
      CROSS_PREFIX="$TOOLCHAIN/bin/arm-linux-androideabi-"
      CFLAGS="-mfloat-abi=softfp -mfpu=neon -mno-thumb -marm -march=$CPU"
      ;;
    x86_64)
      ARCH=x86_64; CPU=x86-64
      CC="$TOOLCHAIN/bin/x86_64-linux-android${API}-clang"
      CXX="$TOOLCHAIN/bin/x86_64-linux-android${API}-clang++"
      CROSS_PREFIX="$TOOLCHAIN/bin/x86_64-linux-android-"
      CFLAGS="-march=$CPU -msse4.2 -mpopcnt -m64 -mtune=x86-64"
      X86ASM_CFG="--enable-x86asm"   # 需要 nasm
      ;;
    *)
      echo "错误: 未知 ABI -> $ABI"; exit 1 ;;
  esac

  echo "==> [$VER/$ABI] configure"
  cd "$WORK"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  ./configure \
    --prefix="$PREFIX" \
    --disable-debug \
    --enable-pic \
    --enable-stripping \
    $POSTPROC_CFG \
    --enable-small \
    --enable-jni \
    --enable-mediacodec \
    --enable-hwaccels \
    $MC_CODEC_CFG \
    $VULKAN_CFG \
    --disable-opengl \
    --enable-static \
    --disable-shared \
    --disable-doc \
    --disable-programs \
    --enable-ffmpeg \
    --disable-ffplay \
    --enable-ffprobe \
    --disable-avdevice \
    --disable-symver \
    --enable-neon \
    --enable-asm \
    ${X86ASM_CFG:---disable-x86asm} \
    --cross-prefix="$CROSS_PREFIX" \
    --target-os=android \
    --arch="$ARCH" \
    --cpu="$CPU" \
    --cc="$CC" \
    --cxx="$CXX" \
    --enable-cross-compile \
    --sysroot="$TOOLCHAIN/sysroot" \
    --extra-cflags="-fPIC -O3 -mno-stackrealign $CFLAGS -Wno-incompatible-function-pointer-types -Wno-int-conversion" \
    --extra-ldflags="-fPIC -Wl,-Bsymbolic -Wl,--exclude-libs,ALL $LDFLAGS" \
    --strip="$STRIP" \
    --nm="$NM" \
    --ar="$AR" \
    --ranlib="$RANLIB" \
    --pkg-config=pkg-config

  echo "==> [$VER/$ABI] make -j${JOBS}"
  make clean
  make -j"${JOBS}"
  make install

  echo "==> [$VER/$ABI] 合并静态库 -> libffmpeg.so"
  printf '{ global: *; };\n' > /tmp/ffmpeg.ver
  "$CC" -shared -o "$PREFIX/libffmpeg.so" \
    -fPIC \
    -Wl,--version-script=/tmp/ffmpeg.ver \
    -Wl,-Bsymbolic \
    -Wl,--whole-archive \
    libavcodec/libavcodec.a \
    libavformat/libavformat.a \
    libswresample/libswresample.a \
    libavfilter/libavfilter.a \
    libavutil/libavutil.a \
    libswscale/libswscale.a \
    -Wl,--no-whole-archive \
    -Wl,--allow-multiple-definition \
    -lm -lz -lnativewindow -llog -landroid $VULKAN_LINK

  echo "==> [$VER/$ABI] 完成 -> $PREFIX"
}

for ABI in "${ABIS[@]}"; do
  build_one "$ABI"
done

echo "==> [$VER/android] 全部完成 (${ABIS[*]})"
