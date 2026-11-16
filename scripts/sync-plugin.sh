#!/usr/bin/env bash
# 把仓库的 plugin/ 同步到 DSH profile 的 node_modules。
#
# 为什么需要：profile 里是 `file:` 依赖，pnpm 是**复制**而不是软链，
# 所以改仓库源码对运行中的 DSH 完全无效——会表现为「改了代码但行为没变」。
# （2026-11-16 为此白调了两轮：改完、重启、还是旧行为。）
#
# 用法：./scripts/sync-plugin.sh [profile]   # 默认 desktop
# 之后需要**手动重启 DSH** 才加载新代码（Node 已 require 旧模块）。

set -euo pipefail

PROFILE="${1:-desktop}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/plugin"
DST="$HOME/.dsh/profiles/$PROFILE/node_modules/dsh-pocket-ios"

if [ ! -d "$DST" ]; then
  echo "✗ 找不到安装副本：$DST" >&2
  echo "  先确认 profile 名（ls ~/.dsh/profiles/）或先 dsh plugin --profile $PROFILE add $SRC" >&2
  exit 1
fi

# 只同步运行时会加载的东西；node_modules / 测试产物不动。
for item in lib package.json locale templates README.md; do
  if [ -e "$SRC/$item" ]; then
    cp -R "$SRC/$item" "$DST/" 2>/dev/null || true
  fi
done

echo "✅ 已同步到 $DST"
echo "⚠️  需要手动重启 DSH 才生效（Node 已经 require 了旧模块）"
