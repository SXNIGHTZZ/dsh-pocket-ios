#!/bin/bash
# 性能压测：按场景启动 App 并采样内存。
#
# 用法：
#   ./scripts/stress-run.sh messages:400
#   ./scripts/stress-run.sh images:120
#   ./scripts/stress-run.sh "messages:400,images:120"
#   ./scripts/stress-run.sh sessions:800          # 只看列表页，不进会话
#
# 环境变量：
#   DSH_STRESS_UDID   目标模拟器 udid（默认 DSH Pocket Max）
#
# 输出：每次场景的内存读数，直接贴进 docs/architecture/performance-baseline.md。
set -u

SCENARIO="${1:-messages:400}"
UDID="${DSH_STRESS_UDID:-2BD221E6-CFAA-4E90-8BEB-E7392ACCCB19}"
BUNDLE_ID="com.ruska.dsh-pocket-ios"

echo "== 场景: $SCENARIO =="

# 1) 确认模拟器在跑
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  echo "启动模拟器 $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  sleep 3
fi

# 2) 找最新 Debug 包（排除 Index.noindex，那里面的包没有 bundle id）
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -name "DSHPocket.app" -path "*Build/Products/Debug-iphonesimulator*" \
  2>/dev/null | grep -v "Index.noindex" | head -1)
if [ -z "$APP" ]; then
  echo "找不到 Debug 包，先跑一次 xcodebuild build" >&2
  exit 1
fi

# 3) 安装 + 带场景启动
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null
xcrun simctl install "$UDID" "$APP" || exit 1
SIMCTL_CHILD_DSH_STRESS="$SCENARIO" \
SIMCTL_CHILD_DSH_DEMO=1 \
SIMCTL_CHILD_DSH_OPEN=demo-1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1

# 4) 等它稳定（会话加载 + 首帧布局）
sleep 8

# 5) 采样 RSS。两个要点：
#    - 必须按 udid 精确匹配：同时开着 iPad 模拟器时会有两个 DSHPocket 进程
#    - 必须多采几次取稳定值：刚启动 + 加载大量数据时是峰值，会误导
sample_rss() {
  ps aux | grep "DSHPocket.app/DSHPocket" | grep -v grep | grep "$UDID" \
    | awk '{printf "%.0f", $6/1024}' | head -1
}

# 等它从启动峰值回落
sleep 6
STABLE=""
for _ in 1 2 3 4; do
  STABLE=$(sample_rss)
  sleep 2
done
echo "进会话后:   ${STABLE} MB  (稳定值)"

# 6) sessions 场景只看列表页，不做滚动
case "$SCENARIO" in
  sessions:*)
    echo "（列表场景，不滚动）"
    exit 0
    ;;
esac

# 7) 标记：滚动一遍要人工或用 ios_sim_interact 触发，
#    这里只采样「稳定后」的内存，滚动压力请配合 dsh-ios 插件或手测。
echo "滚动一遍后请再跑一次本脚本的 --after 模式，或手工对比基线表。"

echo
echo "基线表位置：docs/architecture/performance-baseline.md"
