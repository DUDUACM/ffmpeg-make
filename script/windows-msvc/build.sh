#!/bin/bash
# =============================================================================
# FFmpeg Windows MSVC-ABI 编译脚本 (在 GitHub windows runner 的 bash 里执行)
#
# 用法:  build.sh <version> [arch ...]      arch: x86_64 | arm64
#   例:   build.sh 9.0                      # clang-cl 构建 windows x86_64
#
# 说明:
#   - 源码在线获取: github.com/FFmpeg/FFmpeg.git 按标签 n<版本> 浅克隆 (git 保留 +x)。
#   - 工具链: 镜像自带 clang-cl + llvm 工具 (MSVC ABI), /MT 静态 CRT (产物无 vcredist 依赖);
#     x86_64 原生, arm64 由 clang-cl --target=... 从 x64 宿主交叉。
#   - 纯 LGPL (不开 --enable-gpl / --enable-version3, 禁用 postproc), 便于闭源动态链接。
#   - --enable-hwaccels 启用 D3D11VA/DXVA2 (Windows SDK 头) + NVENC/CUVID (nv-codec-headers
#     在线安装) + Vulkan (Khronos 在线头 + lib.exe 生成 vulkan-1.lib 导入库)。
#   - 输出: 静态库 .lib + 合并的单一 libffmpeg.dll (+ 导入库 .lib) + ffmpeg.exe/ffprobe.exe,
#     写到 build/ffmpeg-<版本>-windows-msvc-<架构>/。适合 MSVC 工程直接链接。
#
# 依赖 (CI 里由 workflow 安装): clang-cl/lld-link/llvm-ar (镜像自带),
#   make + nasm + pkg-config (choco: make nasm pkgconfiglite)。
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
PLATFORM="windows-msvc"
JOBS="${JOBS:-${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 8)}}"

bash "$REPO_ROOT/script/common/fetch-ffmpeg.sh" "$VER"
WORK="$DEPS_DIR/ffmpeg-$VER"

# 用 MSYS2 的 make (POSIX sh/awk 语义正确): choco 的原生 win32 make 跑 FFmpeg
# 的 msvc 依赖生成 awk 脚本会弄坏引号/反斜杠 (gsub(/\/ 报语法错误)
MAKE="make"
if [ -x /c/msys64/usr/bin/make ]; then
  MAKE=/c/msys64/usr/bin/make
fi

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

# ---- 导入 VS / Windows SDK 环境 (INCLUDE/LIB 等, 按目标架构选 vcvarsall 参数) ----
# clang-cl/lld-link 依据这些变量找 SDK 头与库 (arm64 用 SDK 的 arm64 库)。
import_vsenv() {
  local vsarch="$1" vswhere vspath bat raw key val envfile
  vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -x "$vswhere" ] || { echo "错误: 未找到 vswhere.exe (需要 Visual Studio)"; exit 1; }
  vspath="$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')"
  [ -n "$vspath" ] || { echo "错误: vswhere 未定位到 VS 安装路径"; exit 1; }
  bat="$(mktemp).bat"
  raw="$(mktemp)"
  envfile="$(mktemp)"
  {
    echo '@echo off'
    printf 'call "%s\\VC\\Auxiliary\\Build\\vcvarsall.bat" %s >nul\r\n' "$vspath" "$vsarch"
    echo 'set'
  } > "$bat"
  cmd //c "$(cygpath -w "$bat")" | tr -d '\r' > "$raw"
  while IFS='=' read -r key val; do
    case "$key" in
      PATH)
        # cmd 的 PATH 是 Windows 格式 (C:\..;..), 必须转成 POSIX 格式, 否则 bash 找不到命令
        [ -n "${val:-}" ] && printf "export PATH='%s:/usr/bin:/bin'\n" "$(cygpath -p "$val")"
        ;;
      INCLUDE|LIB|LIBPATH|WindowsSDKVersion|WindowsSdkDir|VCINSTALLDIR|VCToolsInstallDir|UniversalCRTSdkDir|UCRTContentRoot|Platform)
        # 这些保持 Windows 格式 (cl/clang-cl/lib.exe 原生读取)
        [ -n "${val:-}" ] && printf "export %s='%s'\n" "$key" "$val"
        ;;
    esac
  done < "$raw" > "$envfile"
  # shellcheck disable=SC1090
  . "$envfile"
  echo "==> VS 环境已导入 (vcvarsall $vsarch)"
}

build_one() {
  local ARCH="$1" TARGET VSARCH MSVC_MACHINE FFARCH CPU CPU_ARG X86ASM_CFG
  local PREFIX="$OUT_BASE/ffmpeg-${VER}-${PLATFORM}-${ARCH}"

  case "$ARCH" in
    x86_64)
      TARGET=""; VSARCH=x64; MSVC_MACHINE=X64
      FFARCH=x86_64; CPU="x86-64"; CPU_ARG="--cpu=$CPU"
      X86ASM_CFG="--enable-x86asm"                      # 需要 nasm
      ;;
    arm64)
      TARGET="--target=aarch64-pc-windows-msvc"; VSARCH=x64_arm64; MSVC_MACHINE=ARM64
      FFARCH=aarch64; CPU=""; CPU_ARG=""
      X86ASM_CFG="--disable-x86asm"
      ;;
    *)
      echo "错误: 未知架构 -> $ARCH (支持 x86_64 | arm64)"; exit 1 ;;
  esac

  import_vsenv "$VSARCH"

  # 自建 prefix: nv-codec-headers + Vulkan 头 + vulkan-1.lib 导入库 + .pc
  # 统一用 mixed 路径 (D:/...): 后续 configure 关闭 MSYS 路径转换, 编译器/
  # pkg-config 收到的路径必须是 Windows 可识别的
  local PREFIX_SYS PREFIX_SYS_M
  PREFIX_SYS="$DEPS_DIR/msvc-prefix-$ARCH"
  PREFIX_SYS_M="$(cygpath -m "$PREFIX_SYS")"
  SUDO="" bash "$REPO_ROOT/script/common/fetch-nvcodec.sh" "$_nvcode_ver" "$PREFIX_SYS_M"
  bash "$REPO_ROOT/script/common/fetch-vulkan.sh" "$VK_VER"
  local VKH="$DEPS_DIR/vulkan-headers-$VK_VER"
  mkdir -p "$PREFIX_SYS/include/vulkan" "$PREFIX_SYS/include/vk_video" "$PREFIX_SYS/lib/pkgconfig"
  cp -a "$VKH/include/vulkan/." "$PREFIX_SYS/include/vulkan/"
  cp -a "$VKH/include/vk_video/." "$PREFIX_SYS/include/vk_video/"
  # 只导出全局函数 (其余运行期 vkGetInstanceProcAddr 取); lib.exe 生成 vulkan-1.lib
  printf 'LIBRARY vulkan-1.dll\nEXPORTS\nvkGetInstanceProcAddr\nvkEnumerateInstanceVersion\nvkEnumerateInstanceExtensionProperties\nvkEnumerateInstanceLayerProperties\nvkCreateInstance\n' > "$DEPS_DIR/vulkan.def"
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 lib.exe \
    /def:"$(cygpath -w "$DEPS_DIR/vulkan.def")" \
    "/machine:$MSVC_MACHINE" \
    "/out:$(cygpath -w "$PREFIX_SYS/lib/vulkan-1.lib")"
  printf 'Name: Vulkan\nDescription: Vulkan\nVersion: %s\nLibs: -L%s/lib -lvulkan-1\nCflags: -I%s/include\n' \
    "$VK_VER" "$PREFIX_SYS_M" "$PREFIX_SYS_M" > "$PREFIX_SYS/lib/pkgconfig/vulkan.pc"
  export PKG_CONFIG_PATH="$PREFIX_SYS_M/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

  echo "==> [$VER/windows-msvc-$ARCH] configure"
  # configure 的临时目录必须用 Windows(mixed) 路径: -Fo/tmp/... 这类附着式前缀参数
  # MSYS 不做路径转换, clang-cl 拿到 POSIX 路径无法写输出文件 (C compiler test failed)
  mkdir -p "$DEPS_DIR/fftmp"
  TMPDIR="$(cygpath -m "$DEPS_DIR/fftmp")"
  export TMPDIR
  cd "$WORK"
  # shellcheck disable=SC2086,SC2046  # 标志位字符串/条件展开是有意的
  # 关闭 MSYS 参数路径转换 (仅本命令): -FoD:/a/... 内嵌的 /a/... 会被 MSYS
  # 误判为盘符路径转换成 A:/..., 拼出非法的 D:A:/...
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 ./configure \
    --prefix="$PREFIX" \
    --disable-debug \
    --disable-stripping \
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
    --target-os=win32 \
    --arch="$FFARCH" \
    $CPU_ARG \
    $( [ -n "$TARGET" ] && echo --enable-cross-compile ) \
    --cc=clang-cl \
    --cxx=clang-cl \
    --ld=clang-cl \
    --ar=llvm-ar \
    --nm=llvm-nm \
    --ranlib=llvm-ranlib \
    --pkg-config=pkg-config \
    --extra-cflags="-MT $TARGET -Wno-unused-command-line-argument -Wno-deprecated-declarations" \
    --extra-ldflags="-MT $TARGET"

  # FFmpeg 为 msvc 生成的依赖跟踪块 (define XDEP ... endef) 内嵌 awk 脚本,
  # 其反斜杠在 MSYS 链路下会被吃掉一层 (gsub(/\/ 语法错误)。一次性 CI 构建
  # 不需要增量依赖, 把这些块替换成"生成空 .d"的无害实现
  awk '
    /^define [A-Z]+DEP$/ { print; print "\t: > $(@:.o=.d)"; in_dep=1; next }
    in_dep && /^endef$/  { print; in_dep=0; next }
    in_dep               { next }
                         { print }
  ' ffbuild/config.mak > ffbuild/config.mak.new && mv ffbuild/config.mak.new ffbuild/config.mak

  echo "==> [$VER/windows-msvc-$ARCH] make -j${JOBS}  ($MAKE)"
  "$MAKE" clean
  "$MAKE" -j"$JOBS"
  "$MAKE" install

  # 从 config.mak 的 EXTRALIBS* 行提取系统库 (*.lib), 合并 DLL 链接用
  local EXTRA_LINK
  EXTRA_LINK="$(grep -E '^EXTRALIBS' ffbuild/config.mak | grep -oE '[A-Za-z0-9_-]+\.lib' | sort -u | tr '\n' ' ' || true)"
  [ -z "$EXTRA_LINK" ] && EXTRA_LINK="kernel32.lib user32.lib bcrypt.lib ole32.lib shell32.lib advapi32.lib ws2_32.lib"
  grep -q '^CONFIG_VULKAN=yes' ffbuild/config.mak && EXTRA_LINK="$EXTRA_LINK vulkan-1.lib"

  echo "==> [$VER/windows-msvc-$ARCH] 合并静态库 -> libffmpeg.dll  (extra=$EXTRA_LINK)"
  mkdir -p "$PREFIX/lib"
  # clang-cl -shared → /DLL; /link 后是 lld-link 参数 (MSYS_NO_PATHCONV 防 /参数被路径转换)
  # shellcheck disable=SC2086  # 标志位字符串按词展开是有意的
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 clang-cl -shared -o "$(cygpath -w "$PREFIX/libffmpeg.dll")" \
    /link \
    /WHOLEARCHIVE:libavcodec.lib \
    /WHOLEARCHIVE:libavformat.lib \
    /WHOLEARCHIVE:libswresample.lib \
    /WHOLEARCHIVE:libavfilter.lib \
    /WHOLEARCHIVE:libavutil.lib \
    /WHOLEARCHIVE:libswscale.lib \
    "/IMPLIB:$(cygpath -w "$PREFIX/lib/libffmpeg.lib")" \
    "/MACHINE:$MSVC_MACHINE" \
    "/LIBPATH:$(cygpath -w "$PREFIX_SYS/lib")" \
    $EXTRA_LINK

  echo "==> [$VER/windows-msvc-$ARCH] 完成 -> $PREFIX"
}

for ARCH in "${ARCHES[@]}"; do
  build_one "$ARCH"
done

echo "==> [$VER/windows-msvc] 全部完成 (${ARCHES[*]})"
