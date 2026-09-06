#!/bin/bash
# =============================================================================
# FFmpeg Windows 交叉编译脚本 (MinGW; 在 Linux / GitHub ubuntu runner 上执行)
#
# 用法:  build.sh <version> [arch ...]      arch: x86_64 | arm64
#   例:   build.sh 9.0                      # 交叉编译 9.0 的 windows x86_64
#         build.sh 9.0 arm64                # 用 llvm-mingw 交叉编译 arm64
#
# 说明:
#   - 源码在线获取: github.com/FFmpeg/FFmpeg.git 按标签 n<版本> 浅克隆 (git 保留 +x)。
#   - 纯 LGPL (不开 --enable-gpl / --enable-version3, 禁用 postproc), 便于闭源动态链接。
#   - x86_64: apt 的 GCC MinGW-w64 (gcc-mingw-w64-x86-64);
#     arm64: llvm-mingw 在线下载 (clang, UCRT 目标), 自动缓存在 $DEPS_DIR。
#   - --enable-hwaccels 启用 D3D11VA/DXVA2 (工具链头自带) + NVENC/CUVID (nv-codec-headers
#     在线安装) + Vulkan (Khronos 在线头 + dlltool 生成 vulkan-1.dll 导入库)。
#   - 输出: 静态库 .a + 合并的单一 libffmpeg.dll (+ 导入库 .dll.a + .def) + ffmpeg.exe,
#     写到 build/ffmpeg-<版本>-windows-<架构>/。
# =============================================================================
set -euo pipefail

VER="${1:?用法: build.sh <version> [arch...]  例如: build.sh 9.0}"
shift || true

if [ "$#" -gt 0 ]; then
  ARCHES=("$@")
else
  ARCHES=(x86_64)
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="${SRC_ROOT:-$REPO_ROOT}"
DEPS_DIR="${DEPS_DIR:-$SRC_ROOT/.deps}"
OUT_BASE="${OUT_BASE:-$SRC_ROOT/build}"
PLATFORM="windows"
JOBS="${JOBS:-$(nproc)}"

# /usr/* 前缀不可写时自动加 sudo (CI runner 用户非 root)
SUDO="${SUDO:-}"
if [ ! -w /usr ] && [ -z "$SUDO" ]; then
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

# ffnvcodec 头版本映射 (NVENC/CUVID, LGPL; FFmpeg 自动检测启用, 版本不兼容则静默跳过)
case "$VER" in
  4.*) _nvcode_ver="9.1.23.3" ;;      # 4.4.x: 8/9.x, 更新 API 不兼容
  5.*) _nvcode_ver="11.1.5.4" ;;      # 5.1.x: 实测 11.x 兼容
  6.*|7.*) _nvcode_ver="12.1.14.1" ;; # 6.1/7.1: 首选范围 >=12.1.14.0
  *)   _nvcode_ver="13.1.15.0" ;;     # 8.x/9.0: 最新
esac

# Vulkan 头版本 (Khronos 在线包)
VK_VER="${VK_HEADERS_VER:-1.4.359}"
bash "$REPO_ROOT/script/common/fetch-vulkan.sh" "$VK_VER"
VKH="$DEPS_DIR/vulkan-headers-$VK_VER"

# llvm-mingw 工具链 (仅 arm64 用; 在线下载, 缓存复用)
# 注意: 进度信息必须走 stderr; stdout 只输出工具链路径 (本函数在命令替换里调用)
LLVM_MINGW_VER="${LLVM_MINGW_VER:-20260826}"
ensure_llvm_mingw() {
  local dir="$DEPS_DIR/llvm-mingw"
  if [ ! -x "$dir/bin/aarch64-w64-mingw32-clang" ]; then
    local tgz="$DEPS_DIR/llvm-mingw-$LLVM_MINGW_VER.tar.xz"
    if [ ! -f "$tgz" ]; then
      echo "==> 在线获取 llvm-mingw $LLVM_MINGW_VER" >&2
      curl -fL --retry 3 -o "$tgz" "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/llvm-mingw-$LLVM_MINGW_VER-ucrt-ubuntu-22.04-x86_64.tar.xz" >&2
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xJf "$tgz" -C "$dir" --strip-components=1
  fi
  echo "$dir"
}

build_one() {
  local ARCH="$1" TRIPLE SYS_PREFIX CC CXX CROSS_PREFIX FFARCH CPU CPU_ARG OPTCFLAGS X86ASM_CFG
  local DLLTOOL_MACHINE DLLTOOL_CMD EXTRA_LDFLAGS
  local PREFIX_OUT="$OUT_BASE/ffmpeg-${VER}-${PLATFORM}-${ARCH}"

  case "$ARCH" in
    x86_64)
      TRIPLE=x86_64-w64-mingw32; SYS_PREFIX="/usr/$TRIPLE"
      CC="$TRIPLE-gcc"; CXX="$TRIPLE-g++"; CROSS_PREFIX="$TRIPLE-"
      FFARCH=x86_64; CPU="x86-64"; CPU_ARG="--cpu=$CPU"; OPTCFLAGS="-march=x86-64"
      X86ASM_CFG="--enable-x86asm"                      # 需要 nasm
      # binutils-mingw-w64 只装带前缀的 dlltool; 机器名是 BFD 风格 i386:x86-64
      DLLTOOL_MACHINE="i386:x86-64"; DLLTOOL_CMD="$TRIPLE-dlltool"
      EXTRA_LDFLAGS="-static-libgcc -static-libstdc++"
      ;;
    arm64)
      local LM; LM="$(ensure_llvm_mingw)"
      TRIPLE=aarch64-w64-mingw32; SYS_PREFIX="$LM/$TRIPLE"
      CC="$LM/bin/$TRIPLE-clang"; CXX="$LM/bin/$TRIPLE-clang++"; CROSS_PREFIX="$LM/bin/$TRIPLE-"
      FFARCH=aarch64; CPU=""; CPU_ARG=""; OPTCFLAGS=""
      X86ASM_CFG="--disable-x86asm"
      DLLTOOL_MACHINE=arm64; DLLTOOL_CMD="$LM/bin/llvm-dlltool"
      EXTRA_LDFLAGS=""                                 # clang 无 libgcc/libstdc++
      ;;
    *)
      echo "错误: 未知架构 -> $ARCH (支持 x86_64 | arm64)"; exit 1 ;;
  esac

  # nv-codec-headers 装进该架构的工具链 prefix (FFmpeg configure 自动检测 ffnvcodec.pc)
  SUDO="$SUDO" bash "$REPO_ROOT/script/common/fetch-nvcodec.sh" "$_nvcode_ver" "$SYS_PREFIX"

  # Vulkan: 覆盖工具链的 vulkan 头 (MinGW 不带/旧) + dlltool 生成 vulkan-1.dll 导入库 + vulkan.pc
  echo "==> [$VER/windows-$ARCH] 安装 vulkan 头 + 导入库 (v$VK_VER)"
  run_as mkdir -p "$SYS_PREFIX/include/vulkan" "$SYS_PREFIX/include/vk_video" "$SYS_PREFIX/lib/pkgconfig"
  run_as cp -a "$VKH/include/vulkan/." "$SYS_PREFIX/include/vulkan/"
  run_as cp -a "$VKH/include/vk_video/." "$SYS_PREFIX/include/vk_video/"
  # 只导出全局函数 (其余运行期 vkGetInstanceProcAddr 取)
  printf 'LIBRARY vulkan-1.dll\nEXPORTS\nvkGetInstanceProcAddr\nvkEnumerateInstanceVersion\nvkEnumerateInstanceExtensionProperties\nvkEnumerateInstanceLayerProperties\nvkCreateInstance\n' > "$DEPS_DIR/vulkan.def"
  run_as "$DLLTOOL_CMD" -m "$DLLTOOL_MACHINE" -d "$DEPS_DIR/vulkan.def" -l "$SYS_PREFIX/lib/libvulkan.a"
  printf 'Name: Vulkan\nDescription: Vulkan\nVersion: %s\nLibs: -lvulkan\n' "$VK_VER" | run_as tee "$SYS_PREFIX/lib/pkgconfig/vulkan.pc" >/dev/null
  export PKG_CONFIG_LIBDIR="$SYS_PREFIX/lib/pkgconfig"   # 让 configure 的 pkg-config 找到 vulkan.pc/ffnvcodec.pc

  echo "==> [$VER/windows-$ARCH] configure"
  cd "$WORK"
  ./configure \
    --prefix="$PREFIX_OUT" \
    --disable-debug \
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
    --target-os=mingw32 \
    --arch="$FFARCH" \
    $CPU_ARG \
    --cross-prefix="$CROSS_PREFIX" \
    --enable-cross-compile \
    --cc="$CC" \
    --cxx="$CXX" \
    --pkg-config=pkg-config \
    --extra-cflags="-O3 $OPTCFLAGS" \
    --extra-ldflags="$EXTRA_LDFLAGS"

  echo "==> [$VER/windows-$ARCH] make -j${JOBS}"
  make clean
  make -j"$JOBS"
  make install

  # 从 config.mak 的 EXTRALIBS* 行提取系统库 (-l...), 合并 DLL 链接用 (含 d3d11/dxva2/winpthread/ws2_32 等)
  local EXTRA_LINK
  EXTRA_LINK="$(grep -E '^EXTRALIBS' ffbuild/config.mak | grep -oE '\-l[A-Za-z0-9_]+' | sort -u | tr '\n' ' ' || true)"
  [ -z "$EXTRA_LINK" ] && EXTRA_LINK="-lm -lwinpthread -lws2_32 -lbcrypt -lole32 -luser32 -lshell32 -ladvapi32"

  echo "==> [$VER/windows-$ARCH] 合并静态库 -> libffmpeg.dll  (extra=$EXTRA_LINK)"
  mkdir -p "$PREFIX_OUT/lib"
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  "$CC" -shared $EXTRA_LDFLAGS -o "$PREFIX_OUT/libffmpeg.dll" \
    -Wl,--whole-archive \
    libavcodec/libavcodec.a \
    libavformat/libavformat.a \
    libswresample/libswresample.a \
    libavfilter/libavfilter.a \
    libavutil/libavutil.a \
    libswscale/libswscale.a \
    -Wl,--no-whole-archive \
    -Wl,--export-all-symbols \
    -Wl,--out-implib,"$PREFIX_OUT/lib/libffmpeg.dll.a" \
    -Wl,--output-def,"$PREFIX_OUT/lib/libffmpeg.def" \
    -Wl,--allow-multiple-definition \
    $EXTRA_LINK

  echo "==> [$VER/windows-$ARCH] 完成 -> $PREFIX_OUT"
}

for ARCH in "${ARCHES[@]}"; do
  build_one "$ARCH"
done

echo "==> [$VER/windows] 全部完成 (${ARCHES[*]})"
