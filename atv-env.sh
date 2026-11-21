#!/bin/bash
# ============================================
#  atv-env.sh —— 本机私有配置的统一加载器
#
#  本文件可以入库：它**不含任何私有值**。
#  设备 UDID / Team ID / 内网地址 / 绝对路径都放在仓库根的 local.env
#  （已被 .gitignore 忽略，永不入库）。模板见 local.env.example。
#
#  local.env 支持的字段:
#    ATV_UDID          必填  Apple TV 的 UDID（xcrun devicectl list devices）
#    ATV_TEAM_ID       必填  免费个人开发者 Team ID（Xcode → 设置 → Accounts）
#    ATV_DEVICE_IP     可选  Apple TV 的局域网 IP，导出公共版时洗白用
#    ATV_PROXY         可选  导出/推送公共仓库用的内网代理 URL
#    ATV_PROJECT_DIR   可选  本仓库绝对路径（内置盘上的续签 watchdog 用）
#    ATV_BILI_IOS_DIR       可选  Bilibili for iOS 项目路径（自动续签它用）
#    ATV_BILI_IPHONE_UDID   可选  装 iPhone 的 iOS 版 UDID（自动续签用）
#    ATV_BILI_IPAD_UDID     可选  装 iPad 的 iOS 版 UDID（自动续签用）
#    ATV_ZEN_DIR       可选  ZenPlayer 项目路径（自动续签 ZenPlayer 用）
#    ZEN_IOS_DIR       可选  ZenPlayer iOS 项目路径（自动续签 iOS 版用）
#    ZETA_IOS_DIR      可选  ZetaBrowser iOS 项目路径（自动续签 iOS 版用）
#    ATV_TEST_SIMULATOR_ID 可选  测试用 tvOS 模拟器 UDID（pre-push 钩子用）
#
#  脚本开头统一三行:
#    . ./atv-env.sh
#    atv_env_load || exit 1
#    atv_require ATV_UDID "Apple TV 的 UDID" || exit 1
#
#  临时覆盖: 命令行传入的同名环境变量优先于 local.env，
#           例: ATV_UDID=00008110-xxxx ./本机-装机-双版本.command
#           需要完全跳过 local.env 时用 ATV_ENV_FILE=/dev/null
# ============================================

ATV_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATV_ENV_KEYS=(ATV_UDID ATV_TEAM_ID ATV_DEVICE_IP ATV_PROXY ATV_PROJECT_DIR ATV_BILI_IOS_DIR ATV_BILI_IPHONE_UDID ATV_BILI_IPAD_UDID ATV_ZEN_DIR ZEN_IOS_DIR ZETA_IOS_DIR ATV_TEST_SIMULATOR_ID)

atv_env_path() { echo "${ATV_ENV_FILE:-$ATV_ENV_DIR/local.env}"; }

# 读取 local.env 并补齐可选项默认值。缺失时返回 1（调用方负责报错退出）。
atv_env_load() {
  local file key value override=""
  file="$(atv_env_path)"
  if [ ! -f "$file" ]; then
    echo "✗ 找不到本机配置文件: $file" >&2
    echo "  修复: cd '$ATV_ENV_DIR' && cp local.env.example local.env" >&2
    echo "        然后按注释填入 Apple TV 的 UDID 与 Team ID" >&2
    return 1
  fi
  # 先把命令行/CI 显式传入的值存起来，source 之后再还原 —— 否则 local.env 会盖掉临时覆盖
  for key in "${ATV_ENV_KEYS[@]}"; do
    eval "value=\${$key:-}"
    [ -n "$value" ] && override="$override$key=$value"$'\n'
  done
  # shellcheck disable=SC1090
  . "$file" || return 1
  if [ -n "$override" ]; then
    while IFS='=' read -r key value; do
      [ -n "$key" ] && export "$key=$value"
    done <<< "$override"
  fi

  : "${ATV_PROJECT_DIR:=$ATV_ENV_DIR}"
  export ATV_PROJECT_DIR
  return 0
}

# 必填项检查。$1=变量名 $2=用途提示（可选）
atv_require() {
  local name="$1" hint="${2:-}" value
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "✗ 缺少必填项 $name${hint:+（$hint）}" >&2
    echo "  在 $(atv_env_path) 里填上它，字段说明见 local.env.example" >&2
    return 1
  fi
  return 0
}

# 把内网地址里的点转义成正则字面量（导出公共版的 sed/终检模式用）
atv_escape_regex() { echo "${1//./\\.}"; }
