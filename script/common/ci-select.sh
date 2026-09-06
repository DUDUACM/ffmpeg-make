#!/bin/bash
# =============================================================================
# workflow_dispatch 选择过滤 (CI 专用)
#
# 用法:  ci-select.sh <platform> <version>
#   例:   ci-select.sh macos 9.0
#
# 说明:
#   - 读取环境变量 SEL_PLATFORMS / SEL_VERSIONS (逗号分隔, 来自 workflow_dispatch
#     inputs; 留空 = 全部)。
#   - 未选中时向 $GITHUB_OUTPUT 写 skip=true, workflow 里后续 step 用
#     `if: steps.<id>.outputs.skip != 'true'` 跳过。
#   - tag 触发时 inputs 为空 → 全部选中。
# =============================================================================
set -euo pipefail

platform="${1:?用法: ci-select.sh <platform> <version>}"
version="${2:?用法: ci-select.sh <platform> <version>}"

sel_platforms="$(echo "${SEL_PLATFORMS:-}" | tr -d ' ')"
sel_versions="$(echo "${SEL_VERSIONS:-}" | tr -d ' ')"

skip=false
if [ -n "$sel_platforms" ] && ! echo ",$sel_platforms," | grep -q ",$platform,"; then
  skip=true
fi
if [ "$skip" = false ] && [ -n "$sel_versions" ] && ! echo ",$sel_versions," | grep -q ",$version,"; then
  skip=true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "skip=$skip" >> "$GITHUB_OUTPUT"
fi
echo "==> select: platform=$platform version=$version skip=$skip"
