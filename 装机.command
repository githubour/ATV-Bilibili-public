#!/bin/bash
set -o pipefail
# ============================================
#  装机.command —— Release 构建 + 直接安装到 Apple TV
#
#  用途：免费 Apple ID 的描述文件 7 天到期后，双击本文件即可重新签名并安装
#        （Xcode 会自动续签描述文件，前提是 Xcode 里登录了 Apple ID）
#
#  必填
#    ATV_UDID         Apple TV 的 UDID，用 `xcrun devicectl list devices` 查
#  可选
#    ATV_BUNDLE_ID    覆盖 bundle id（默认取工程里的 APP_BUNDLE_ID）
#    ATV_TEAM_ID      覆盖 DEVELOPMENT_TEAM（用自动签名时需要填自己的 Team）
#    ATV_DISPLAY_NAME 覆盖 App 显示名
#    ATV_ICON_NAME    覆盖图标资源名
#
#  怎么填（任选其一）
#    a) 直接改本文件开头的 ATV_UDID
#    b) 同目录建 `本机-配置.sh`（已被 .gitignore 忽略）写好这些变量
#    c) 运行时传入：ATV_UDID=00008110-xxxx ATV_TEAM_ID=YYYYYYYYYY ./装机.command
#
#  前提：Mac 与 Apple TV 在同一局域网；电视上 设置→隐私与安全性→开发者模式 已开启
# ============================================
cd "$(dirname "$0")" || exit 1

[ -f ./本机-配置.sh ] && . ./本机-配置.sh

ATV_UDID="${ATV_UDID:-}"
ATV_BUNDLE_ID="${ATV_BUNDLE_ID:-}"
ATV_TEAM_ID="${ATV_TEAM_ID:-}"
ATV_DISPLAY_NAME="${ATV_DISPLAY_NAME:-}"
ATV_ICON_NAME="${ATV_ICON_NAME:-}"

if [ -z "$ATV_UDID" ]; then
  cat <<'EOF'
✗ 还差一个必填项：Apple TV 的 UDID

  查法:  xcrun devicectl list devices
  填法（任选）:
    a) 直接改本文件开头的 ATV_UDID
    b) 在同目录建 `本机-配置.sh`，写：ATV_UDID="00008110-xxxxxxxxxxxxxxxx"
    c) 运行时传入：ATV_UDID=00008110-xxxxxxxxxxxxxxxx ./装机.command
EOF
  exit 1
fi

echo "▶ 正在定位 Apple TV ($ATV_UDID)..."
xcrun devicectl list devices 2>/dev/null | grep -qi "$ATV_UDID\|apple tv" || {
  echo "✗ 没找到 Apple TV。请确认:"
  echo "  1. Apple TV 与本机在同一局域网（同一 WiFi 网段）"
  echo "  2. 电视已唤醒 —— 待机状态无法安装"
  echo "  3. 电视上 设置→隐私与安全性→开发者模式 已开启，并重启过"
  exit 1
}

ARGS=()
[ -n "$ATV_BUNDLE_ID" ] && ARGS+=(APP_BUNDLE_ID="$ATV_BUNDLE_ID")
[ -n "$ATV_TEAM_ID" ] && ARGS+=(DEVELOPMENT_TEAM="$ATV_TEAM_ID")
[ -n "$ATV_DISPLAY_NAME" ] && ARGS+=(BUNDLE_DISPLAY_NAME="$ATV_DISPLAY_NAME")
[ -n "$ATV_ICON_NAME" ] && ARGS+=(APP_ICON_NAME="$ATV_ICON_NAME")

echo "▶ 构建（Release，用 Xcode 里已登录的 Apple ID 自动签名）..."
xcodebuild -project ATV-Bilibili.xcodeproj \
  -scheme ATV-Bilibili \
  -configuration Release \
  -destination "platform=tvOS,id=$ATV_UDID" \
  -allowProvisioningUpdates \
  "${ARGS[@]}" \
  build 2>&1 | tail -30 || {
  echo "✗ 构建失败，请把上面的报错贴出来"
  exit 1
}

# 只匹配真机产物目录 appletvos —— 必须排除 appletvsimulator：
# 模拟器产物混装会报 0xe8008014 invalid signature
APP=$(find ~/Library/Developer/Xcode/DerivedData/ -name 'ATV-Bilibili.app' -path '*Release-appletvos*' -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)
[ -n "$APP" ] || {
  echo "✗ 没找到构建产物，请把上面的报错贴出来"
  exit 1
}

echo "▶ 安装到 Apple TV..."
xcrun devicectl device install app --device "$ATV_UDID" "$APP" || {
  echo "✗ 安装失败。常见原因:"
  echo "  - 描述文件过期且 Xcode 未登录 Apple ID（打开 Xcode→Settings→Accounts 检查）"
  echo "  - Apple TV 弹出了信任确认，请看电视屏幕点「信任」"
  exit 1
}

echo
echo "✓ 完成！Apple TV 主屏上点开即可。"
echo "  （如果打开闪退，说明签名身份变化，删除这个 App 后再运行本脚本一次）"
