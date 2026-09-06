# ffmpeg-make

FFmpeg 多平台构建系统（GitHub Actions，全在线依赖）。支持 **macOS + Windows（MinGW / MSVC 双工具链）+ Linux(Ubuntu) + Android**，纯 LGPL 配置（可闭源动态链接）。

## 支持范围

| 平台 | 架构 | Runner | 工具链 | 硬件加速 |
| --- | --- | --- | --- | --- |
| macOS | x86_64 / arm64 | macos-15-intel / macos-15 | 原生 clang | VideoToolbox |
| Windows (MinGW) | x86_64 / arm64 | ubuntu-24.04 交叉 | GCC MinGW-w64（x86_64）+ llvm-mingw（arm64） | D3D11VA/DXVA2 + NVENC/CUVID + Vulkan |
| Windows (MSVC) | x86_64 / arm64 | windows-2025 | clang-cl（MSVC ABI，`/MT` 静态 CRT） | 同上 |
| Linux | x86_64 / arm64 | ubuntu-24.04 / ubuntu-24.04-arm | 原生 gcc | VAAPI + NVENC/CUVID + Vulkan |
| Android | arm64-v8a / armeabi-v7a / x86_64 | ubuntu-24.04 交叉 | NDK r27d（API 28） | mediacodec + Vulkan |

FFmpeg 版本：`4.4.8` / `5.1.10` / `6.1.6` / `7.1.5` / `8.0.3` / `8.1.2` / `9.0`（官方维护版）

**7 版本 × 11 目标 = 77 个产物。**

> Windows 双工具链说明：MinGW 产物（`ffmpeg-<版本>-windows-<架构>`）与参考仓库一致；MSVC 产物（`ffmpeg-<版本>-windows-msvc-<架构>`）是 MSVC ABI、静态 CRT（无 vcredist 依赖），自带 `.lib` 导入库，适合 MSVC 工程直接链接。

## 全部在线依赖（仓库不存放任何源码包）

| 依赖 | 版本 | 来源 |
| --- | --- | --- |
| FFmpeg 源码 | 按标签 `n<版本>` 浅克隆 | https://github.com/FFmpeg/FFmpeg.git |
| nv-codec-headers | 9.1.23.3 / 11.1.5.4 / 12.1.14.1 / 13.1.15.0（按 FFmpeg 版本映射） | https://github.com/FFmpeg/nv-codec-headers |
| Vulkan-Headers | 1.4.359 | https://github.com/KhronosGroup/Vulkan-Headers |
| Android NDK | r27d | https://dl.google.com/android/repository/ |
| llvm-mingw | 20260826（ucrt, ubuntu-22.04 x86_64） | https://github.com/mstorsjo/llvm-mingw |
| clang-cl / lld-link / VS2022 | 镜像自带（LLVM 20.1.8） | windows-2025 runner |

nv-codec-headers 版本映射：FFmpeg 4.x → 9.1.23.3；5.x → 11.1.5.4；6.x/7.x → 12.1.14.1；8.x/9.0 → 13.1.15.0。

> Vulkan：用 Khronos 1.4.x 在线头覆盖构建环境的 vulkan 头（NDK/系统自带的 1.3.275 不够 FFmpeg 7.1.5+ 的 ≥1.3.277 要求），运行期仍链接 NDK/系统的 libvulkan 加载器。

## 编解码器与特性矩阵

所有版本均含**完整 LGPL 软件编解码集**（H.264/HEVC/AV1/VP9/VP8/Opus/AAC/… 解码+编码，FFmpeg 默认全集）。下表只列**硬件加速**部分。

### macOS（VideoToolbox）

| 类别 | 编解码器 | 版本覆盖 |
| --- | --- | --- |
| VideoToolbox 硬件解码（hwaccel） | h264 / hevc / mpeg2 / mpeg4 / vp9 等 | 全部 7 版本 |
| VideoToolbox 硬件编码 | h264 / hevc | 全部 7 版本 |

### Linux（VAAPI + CUVID/NVENC + Vulkan）

| 类别 | 编解码器 | 版本覆盖 |
| --- | --- | --- |
| VAAPI 硬件解码 | h264 / hevc / av1 / vp9 / vp8 / mpeg2 / mpeg4 / vc1 / wmv3 / h263 | 全部 7 版本 |
| VAAPI 硬件编码 | h264 / hevc / mjpeg / mpeg2 / vp8 / vp9 | 全部 7 版本 |
| VAAPI 硬件编码 | av1 | 6.1.6+ |
| CUVID 硬件解码（NVIDIA） | h264 / hevc / vp9 | 全部 7 版本 |
| CUVID 硬件解码（NVIDIA） | av1 | 5.1.10+ |
| NVENC 硬件编码（NVIDIA） | h264 / hevc | 全部 7 版本 |
| NVENC 硬件编码（NVIDIA） | av1 | 6.1.6+ |
| Vulkan 硬件解码（hwaccel） | h264 / hevc / av1 / vp9 | 全部（在线 1.4 头） |
| Vulkan 硬件编码 | h264 / hevc / av1 | 7.1.5+ |

### Windows（D3D11VA/DXVA2 + CUVID/NVENC + Vulkan，MinGW 与 MSVC 相同）

| 类别 | 编解码器 | 版本覆盖 |
| --- | --- | --- |
| D3D11VA / DXVA2 硬件解码 | h264 / hevc / av1 / vp9 / mpeg2 / vc1 / wmv3 | 全部 7 版本 |
| CUVID 硬件解码（NVIDIA） | h264 / hevc / vp9 | 全部 7 版本 |
| CUVID 硬件解码（NVIDIA） | av1 | 5.1.10+ |
| NVENC 硬件编码（NVIDIA） | h264 / hevc | 全部 7 版本 |
| NVENC 硬件编码（NVIDIA） | av1 | 6.1.6+ |
| Vulkan 硬件解码（hwaccel） | h264 / hevc / av1 / vp9 | 全部（在线 1.4 头） |
| Vulkan 硬件编码 | h264 / hevc / av1 | 7.1.5+ |

### Android（mediacodec + Vulkan）

| 类别 | 编解码器 | 版本覆盖 |
| --- | --- | --- |
| mediacodec 硬件解码 | h264 / hevc / vp8 / vp9 / mpeg4 / mpeg2 | 全部 7 版本 |
| mediacodec 硬件解码 | av1 + 音频(aac/mp3/amrnb/amrwb) | 6.1.6+ |
| mediacodec 硬件编码 | h264 / hevc / av1 / mpeg4 / vp8 / vp9 | 6.1.6+ |
| Vulkan 硬件解码（hwaccel） | h264 / hevc / av1 / vp9 | 全部（在线 1.4 头） |
| Vulkan 硬件编码 | h264 / hevc / av1 | 7.1.5+ |

> 硬件编解码依赖目标机有对应 GPU + 驱动；无 GPU 时回退到软件编解码（同样可用）。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/check.yml` | push / PR：脚本语法检查（bash -n + shellcheck） |
| `.github/workflows/build.yml` | 主工作流：5 个构建 job（平台 × 架构 × 版本矩阵）+ 测试 + 发布 |
| `script/common/` | 在线获取脚本（FFmpeg / nv-codec-headers / Vulkan-Headers）+ CI 选择过滤 |
| `script/macos/` | macOS 构建脚本（VideoToolbox） |
| `script/windows/` | Windows MinGW 交叉脚本（GCC + llvm-mingw） |
| `script/windows-msvc/` | Windows MSVC-ABI 脚本（clang-cl，windows runner 上执行） |
| `script/linux/` | Linux 构建脚本（x86_64 / arm64，VAAPI + NVENC/CUVID + Vulkan） |
| `script/android/` | Android 交叉脚本（NDK，4 ABI） |
| `build/` | 编译产物（`.gitignore` 忽略，本地 / CI 生成） |
| `.deps/` | 在线依赖缓存（源码 / NDK / llvm-mingw，`.gitignore` 忽略） |

## GitHub Actions 用法

### 手动构建（迭代 / 验证）

Actions → **build** → Run workflow，可填：

- `platforms`：`macos,windows,windows-msvc,linux,android` 的逗号子集（留空 = 全部）
- `versions`：如 `9.0` 或 `9.0,8.1.2`（留空 = 全部 7 个）

选中的矩阵单元才真正执行（未选中的 job 秒级跳过）。

### 发布（全量 98 产物）

```bash
git tag v1.0.0
git push origin v1.0.0
```

tag 触发：全量 5 个构建 job 并行（macOS 14 + Windows MinGW 14 + Windows MSVC 14 + Linux 14 + Android 21 个编译）→ `test` 阶段在 ubuntu / macos / windows runner 上**原生运行** 9.0 版本的 ffmpeg 做转码功能测试 → `release` 阶段把 77 个 `ffmpeg-*.tar.xz` 上传到 GitHub Release（自动生成 Release Notes）。

> 公开仓库所有 runner（含 macos-15-intel、ubuntu-24.04-arm）免费。macOS 并发上限较低，14 个 macOS job 会分批排队。

## 本地构建

脚本可在本地直接跑（依赖在线获取，需自备编译环境）：

```bash
# macOS (在 Mac 上, 默认当前机器架构)
brew install nasm pkg-config
bash script/macos/build.sh 9.0            # 或 9.0 x86_64 / 9.0 arm64

# Linux (x86_64 机器; arm64 需在 arm 机器上)
sudo apt-get install make nasm yasm pkg-config xz-utils build-essential curl git zlib1g-dev libva-dev libdrm-dev libvulkan-dev
bash script/linux/build.sh 9.0

# Windows MinGW 交叉 (Linux 上)
sudo apt-get install gcc-mingw-w64-x86-64 make nasm yasm pkg-config xz-utils build-essential curl git
bash script/windows/build.sh 9.0 x86_64

# Android (Linux 上; NDK 自动下载到 .deps/)
sudo apt-get install make nasm yasm pkg-config xz-utils build-essential curl git unzip
bash script/android/build.sh 9.0 arm64-v8a

# 构建全部 7 个版本
bash script/<platform>/build-all.sh
```

环境变量（可选）：`JOBS`（并行数）、`DEPS_DIR`（依赖缓存目录，默认 `<仓库根>/.deps`）、`OUT_BASE`（产物目录，默认 `<仓库根>/build`）、`VK_HEADERS_VER`、`NDK_VERSION`、`LLVM_MINGW_VER`。

## 产物

每个「版本 × 平台 × 架构」组合一个目录，内含合并的单一动态库（Android/Linux 是 `libffmpeg.so`，Windows 是 `libffmpeg.dll`，macOS 是 `libffmpeg.dylib`）+ 静态库 + 头文件 + `bin/ffmpeg` 和 `bin/ffprobe`（Windows 为 `.exe`）：

```text
build/ffmpeg-<版本>-<平台>-<架构>/
例如: build/ffmpeg-9.0-macos-arm64/
      build/ffmpeg-9.0-linux-x86_64/
      build/ffmpeg-9.0-android-arm64-v8a/
      build/ffmpeg-9.0-windows-x86_64/        (MinGW)
      build/ffmpeg-9.0-windows-msvc-arm64/    (MSVC ABI)
```

Windows MinGW 产物含 `libffmpeg.dll` + `lib/libffmpeg.dll.a` + `lib/libffmpeg.def`；MSVC 产物含 `libffmpeg.dll` + `lib/libffmpeg.lib`。

## 许可证

纯 **LGPL**（不开 `--enable-gpl` / `--enable-version3`，禁用 GPL 的 `postproc`）——可闭源 App 动态链接分发。VideoToolbox / VAAPI / Vulkan / mediacodec / D3D11VA 硬件编解码器同样 LGPL（不是 GPL）。

> ⚠️ **运行期依赖**（启用了硬件加速）：
>
> - **macOS**：无额外依赖（VideoToolbox 为系统 framework，macOS 11+）。
> - **Linux**：`apt install libva2 libvulkan1` + 显卡驱动（Intel `intel-media-va-driver` / AMD `mesa-va-drivers` / NVIDIA 驱动）。NVENC/CUVID 不增加 `.so` 链接（运行期 dlopen），但实际用 NVIDIA 编解码时需装 NVIDIA 专有驱动（提供 `libcuda.so.1`）。
> - **Windows**：`libffmpeg.dll` 只依赖 Windows 系统 DLL（d3d11/dxva2/kernel32 等，系统自带）；MinGW 运行期已静态链入，MSVC 版用 `/MT` 静态 CRT。NVENC/CUVID 需 NVIDIA 显卡 + 驱动。
> - **Android**：Vulkan 需 Android 7.0+（API 24）且设备支持 Vulkan；mediacodec 硬解走系统，无额外依赖。
