#!/bin/bash
set -o pipefail
# ============================================
#  装机-公共.sh —— 装机流程的唯一实现
#
#  「定位电视 → xcodebuild → 找产物 → devicectl 安装」这一串原本在三个入口里各抄了一份，
#  现在收在这里；三个入口只剩「设好环境变量 + 调 atv_install」：
#    · 装机.command           读 本机-配置.sh（或命令行传入），中性兜底
#    · 本机-装机-example.command  把值写死在本机脚本里（不导出到公共仓库）
#    · 本机-装机-example.command  同上
#
#  入参（环境变量）
#    ATV_UDID          必填。Apple TV 的 UDID，查法: xcrun devicectl list devices
#    ATV_BUNDLE_ID     可选。覆盖工程里的 APP_BUNDLE_ID
#    ATV_TEAM_ID       可选。覆盖 DEVELOPMENT_TEAM（自动签名时填自己的 Team）
#    ATV_DISPLAY_NAME  可选。App 显示名
#    ATV_ICON_NAME     可选。图标资源名（多版本并存时用来区分）
#    ATV_LABEL         可选。输出里的版本标签，如「example版」，仅影响文案
#
#  返回码: 0 成功 / 1 失败（由调用方透传成自己的退出码）
#
#  ⚠ 这里的输出是契约，不要随意改：
#    · 签名自动续签.sh 会在整个脚本输出里 grep "BUILD SUCCEEDED" 判定构建是否成功，
#      并 grep 设备不可达特征串（休眠/离线）判断值不值得下个周期重试
#    · 因此构建日志必须照常打印（保留 `tail -30` 让该行留在输出里），
#      失败文案也保持原样
# ============================================

atv_install() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  cd "$root" || return 1

  local udid="${ATV_UDID:-}"
  if [ -z "$udid" ]; then
    echo "✗ 缺少 ATV_UDID（Apple TV 的 UDID）"
    return 1
  fi

  local tag=""
  [ -n "${ATV_LABEL:-}" ] && tag="[${ATV_LABEL}] "

  echo "▶ ${tag}正在定位 Apple TV ($udid)..."
  xcrun devicectl list devices 2>/dev/null | grep -qi "$udid\|apple tv" || {
    echo "✗ 没找到 Apple TV。请确认:"
    echo "  1. Apple TV 与本机在同一局域网（同一 WiFi 网段）"
    echo "  2. 电视已唤醒 —— 待机状态无法安装"
    echo "  3. 电视上 设置→隐私与安全性→开发者模式 已开启，并重启过"
    return 1
  }

  local args=()
  [ -n "${ATV_BUNDLE_ID:-}" ] && args+=(APP_BUNDLE_ID="$ATV_BUNDLE_ID")
  [ -n "${ATV_TEAM_ID:-}" ] && args+=(DEVELOPMENT_TEAM="$ATV_TEAM_ID")
  [ -n "${ATV_DISPLAY_NAME:-}" ] && args+=(BUNDLE_DISPLAY_NAME="$ATV_DISPLAY_NAME")
  [ -n "${ATV_ICON_NAME:-}" ] && args+=(APP_ICON_NAME="$ATV_ICON_NAME")

  echo "▶ ${tag}构建（Release，用 Xcode 里已登录的 Apple ID 自动签名）..."
  # tee 全量日志到固定文件：xcodebuild 真正的报错常在 tail -30 之外，失败时只看最后 30 行经常不够定位。
  # 注意输出契约：签名自动续签.sh 会 grep 本段输出里的 "BUILD SUCCEEDED" 与设备不可达特征串，
  # tee+tail 保持它们照常出现在 stdout，失败文案也只追加不改写。
  local log="$HOME/Library/Logs/atv-bilibili-build.log"
  mkdir -p "$(dirname "$log")"
  xcodebuild -project ATV-Bilibili.xcodeproj \
    -scheme ATV-Bilibili \
    -configuration Release \
    -destination "platform=tvOS,id=$udid" \
    -allowProvisioningUpdates \
    "${args[@]}" \
    build 2>&1 | tee "$log" | tail -30 || {
    echo "✗ 构建失败，请把上面的报错贴出来（完整日志: $log）"
    return 1
  }

  # 只匹配真机产物目录 appletvos —— 必须排除 appletvsimulator：
  # 模拟器产物混装会报 0xe8008014 invalid signature
  local app
  app=$(find ~/Library/Developer/Xcode/DerivedData/ -name 'ATV-Bilibili.app' -path '*Release-appletvos*' -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)
  [ -n "$app" ] || {
    echo "✗ 没找到构建产物，请把上面的报错贴出来"
    return 1
  }

  echo "▶ ${tag}安装到 Apple TV..."
  xcrun devicectl device install app --device "$udid" "$app" || {
    echo "✗ 安装失败。常见原因:"
    echo "  - 描述文件过期且 Xcode 未登录 Apple ID（打开 Xcode→Settings→Accounts 检查）"
    echo "  - Apple TV 弹出了信任确认，请看电视屏幕点「信任」"
    return 1
  }

  echo
  echo "✓ ${tag}完成！主屏上的「${ATV_DISPLAY_NAME:-哔哩哔哩}」已更新。"
  echo "  （如果打开闪退，说明签名身份变化：删掉这个 App 再运行本脚本一次）"
  return 0
}
