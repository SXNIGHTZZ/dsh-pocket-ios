#!/usr/bin/env bash
#
# 一键发布到 App Store：打包 → 导出 ipa → 归档 → 上传。
#
# 为什么要有这个脚本：之前每次都用 `-archivePath /tmp/...`，图快，
# 结果 /tmp 一重启就没了，历史上传记录在本地一份都没留（2026-11-15 发现）。
# 现在每次产物都会落到 ~/projects/dsh-pocket-ios-archives/<版本>-<build>/，
# 同时写 manifest.jsonl，deliveryUuid 能和 App Store Connect 的记录对上。
#
# 用法：
#   ./scripts/release.sh              # 完整流程（含上传）
#   ./scripts/release.sh --no-upload  # 只打包归档，不上传
#
# 前置：Info.plist 里的版本号/build 已经改好；~/.zshrc 里配好 ASC_KEY_ID / ASC_ISSUER_ID。

set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw Info.plist)
ARCH_ROOT="$HOME/projects/dsh-pocket-ios-archives"
DEST="$ARCH_ROOT/${VERSION}-${BUILD}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> 目标版本：$VERSION ($BUILD)"

if [ -d "$DEST" ]; then
  echo "!! 该版本已归档：$DEST"
  echo "   要重新发布请先改 Info.plist 的版本号或 build 号。"
  exit 1
fi

echo "==> archive"
xcodebuild archive \
  -project DSHPocket.xcodeproj -scheme DSHPocket -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK/DSHPocket.xcarchive" \
  -allowProvisioningUpdates >/dev/null

echo "==> export ipa"
xcodebuild -exportArchive \
  -archivePath "$WORK/DSHPocket.xcarchive" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$WORK/export" \
  -allowProvisioningUpdates >/dev/null

echo "==> 归档到 $DEST"
mkdir -p "$DEST"
cp "$WORK/export/DSHPocket.ipa" "$DEST/"
cp -R "$WORK/DSHPocket.xcarchive/dSYMs/DSHPocket.app.dSYM" "$DEST/" 2>/dev/null || true

DELIVERY=""
if [ "$UPLOAD" = "1" ]; then
  echo "==> 上传到 App Store Connect"
  OUT=$(zsh -c 'source ~/.zshrc 2>/dev/null; env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY \
        xcrun altool --upload-app -f '"$DEST"'/DSHPocket.ipa -t ios \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json' 2>&1)
  echo "$OUT" | tail -5
  DELIVERY=$(echo "$OUT" | grep -o '"delivery-uuid"[^,]*' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
else
  echo "==> 跳过上传（--no-upload）"
fi

COMMIT=$(git rev-parse HEAD)
cat > "$DEST/meta.json" <<META
{
  "version": "$VERSION",
  "build": "$BUILD",
  "bundleId": "com.ruska.dsh-pocket-ios",
  "archiveDate": "$(date -Iseconds)",
  "gitCommit": "$COMMIT",
  "deliveryUuid": "${DELIVERY:-}",
  "notes": ""
}
META

printf '{"version":"%s","build":"%s","date":"%s","commit":"%s","deliveryUuid":"%s","dir":"%s-%s"}\n' \
  "$VERSION" "$BUILD" "$(date -Iseconds)" "$COMMIT" "${DELIVERY:-}" "$VERSION" "$BUILD" \
  >> "$ARCH_ROOT/manifest.jsonl"

echo ""
echo "==> 完成"
echo "    归档：$DEST"
echo "    索引：$ARCH_ROOT/manifest.jsonl"
echo "    下一步：去 App Store Connect 创建版本、关联 build、填审核信息并提交。"
