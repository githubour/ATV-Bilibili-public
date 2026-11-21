#!/bin/bash
set -o pipefail
# ============================================
#  装机.command —— Release 构建 + 直接安装到 Apple TV（中性兜底入口）
#
#  真正的流程在 装机-公共.sh；本文件只负责读本机配置、校验必填项、然后调它。
#  （多版本并存的两个入口见 本机-装机-example.command / 本机-装机-example.command，
#    它们把下面这些值直接写死，不读本机配置。）
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
#    a) 复制模板填自己的值：cp local.env.example local.env（推荐，已 gitignore）
#    b) 运行时传入：ATV_UDID=00008110-xxxx ATV_TEAM_ID=YYYYYYYYYY ./装机.command
#       （命令行传入的同名变量优先于 local.env）
#
#  前提：Mac 与 Apple TV 在同一局域网；电视上 设置→隐私与安全性→开发者模式 已开启
# ============================================
cd "$(dirname "$0")" || exit 1

. ./atv-env.sh
atv_env_load || exit 1
atv_require ATV_UDID "Apple TV 的 UDID，查法: xcrun devicectl list devices" || {
  cat <<'EOF'

  填法（任选）:
    a) cp local.env.example local.env，然后填 ATV_UDID（推荐）
    b) 运行时传入：ATV_UDID=00008110-xxxxxxxxxxxxxxxx ./装机.command
EOF
  exit 1
}

. ./装机-公共.sh
atv_install || exit 1
