#!/bin/bash
# =============================================================================
# 构建全部 7 个版本 (Windows MSVC-ABI, 在 windows runner 的 bash 里执行)。
#
#   build-all.sh                     # 全部 7 版本 (x86_64)
#   build-all.sh arm64               # 全部版本, 指定架构
#   build-all.sh 9.0                 # 只构建 9.0
#   build-all.sh 9.0 x86_64          # 只构建 9.0 的 x86_64
# =============================================================================
set -euo pipefail

VERSIONS=(4.4.8 5.1.10 6.1.6 7.1.5 8.0.3 8.1.2 9.0)
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 0 ] && echo "$1" | grep -qE '^[0-9]+\.[0-9]+'; then
  # 第一个参数是版本: 透传给 build.sh (版本 + 架构)
  bash "$DIR/build.sh" "$@"
else
  for v in "${VERSIONS[@]}"; do
    echo "############################################################"
    echo "#  开始构建 ffmpeg-$v (windows-msvc)"
    echo "############################################################"
    bash "$DIR/build.sh" "$v" "$@"
  done
  echo "全部 windows-msvc 版本构建完成: ${VERSIONS[*]}"
fi
