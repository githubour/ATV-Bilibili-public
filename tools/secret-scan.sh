#!/bin/sh
# 仓库级 secret / PII 扫描：只扫 git 跟踪文件，零依赖、不联网。
#
# 设计约束（GMP 的教训）：**扫描器不得排除自身**。
# 一旦把 scripts/ 排除掉，脚本里写错规则、或有人把密钥塞进脚本，扫描就永远发现不了。
# 所以这里的敏感词全部按片段拼接，脚本源码本身不会命中自己的规则——
# 这样才不需要「把自己加进白名单」这种自欺欺人的做法。
#
# 用法：
#   sh tools/secret-scan.sh                      # 密钥扫描（私有仓默认）
#   SCAN_PROFILE=pii sh tools/secret-scan.sh     # 追加内网地址 / 个人标识（公开仓用）
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "跳过：不在 git 仓库内" >&2
  exit 0
}

PATTERNS=$(mktemp)
trap 'rm -f "$PATTERNS"' EXIT

cat >"$PATTERNS" <<'EOF'
-----BEGIN [A-Z ]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
gh[pousr]_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
sk-[A-Za-z0-9]{24,}
xox[baprs]-[A-Za-z0-9-]{10,}
(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APP_SECRET|APP_CODE|ACCESS_KEY)[[:space:]]*[:=][[:space:]]*["'][A-Za-z0-9_+/=-]{16,}["']
EOF

if [ "${SCAN_PROFILE:-secrets}" = "pii" ]; then
  # 公开仓才查：私有仓里出现内网地址、本机路径是正常的，公开仓里出现就是泄露。
  # 路径规则的字面量拆成变量再拼：否则规则文件自己就命中自己（扫描器不得自我豁免，
  # 所以也不能靠排除 scripts/ 来绕过这个问题）。
  # user_prefix 还得拆字拼：字面量直写本机家目录前缀，会让导出公共版的终检
  # （本机路径敏感词）命中本脚本自身——同一个理由，下面两条个人标识词也是拆字拼的。
  home_prefix='/Volumes/'
  user_prefix="$(printf '/%s' 'Users/')"
  {
    printf '%s\n' '[a-z0-9][a-z0-9-]*\.ts\.net'
    printf '%s%s\n' "$home_prefix" '[^/]+/'
    printf '%s%s\n' "$user_prefix" '[A-Za-z0-9._-]+/'
    printf '%s\n' "$(printf 'zhi%sbin' '')"
    printf '%s\n' "$(printf '志%s斌' '')"
  } >>"$PATTERNS"
fi

# 各仓自己的内网地址 / 业务词（导出时会被替换成占位符的那批）由 CI 注入，不写死在通用脚本里
if [ -n "${PII_EXTRA_RE:-}" ]; then
  printf '%s\n' "$PII_EXTRA_RE" >>"$PATTERNS"
fi

# git grep 只搜跟踪文件：0 = 有命中，1 = 没有命中，>1 = 扫描器自己出错。
# 必须把 >1 单独判成失败——否则参数写错（比如给 git grep 传它不认识的 grep 选项）
# 会被当成「没有命中」，扫描器静默失效，比不扫更危险。
ERRLOG=$(mktemp)
trap 'rm -f "$PATTERNS" "$ERRLOG"' EXIT
# 第三方 vendored 源码里的测试夹具常带 PEM 头之类的假凭据，按需排除；
# 路径是显式的、写在 CI 里的，不是脚本偷偷给自己开的后门。
EXCLUDES=""
for path in ${SCAN_EXCLUDE:-}; do
  EXCLUDES="$EXCLUDES :(exclude)$path"
done

status=0
# shellcheck disable=SC2086  # EXCLUDES 需要按空格拆成多个 pathspec
HITS=$(git grep -nIE -f "$PATTERNS" -- . $EXCLUDES 2>"$ERRLOG") || status=$?

if [ "$status" -gt 1 ]; then
  echo "✗ 扫描器自身出错（git grep 退出码 $status）：" >&2
  sed 's/^/    /' "$ERRLOG" >&2
  exit 2
fi

if [ "$status" -eq 0 ]; then
  echo "✗ 发现疑似敏感内容（$(printf '%s\n' "$HITS" | wc -l | tr -d ' ') 处）：" >&2
  printf '%s\n' "$HITS" | sed 's/^/    /' >&2
  echo "  确认是误报就把该行改成明确的占位符（<redacted> / \${VAR}），不要加白名单。" >&2
  exit 1
fi

echo "✓ secret 扫描通过（profile=${SCAN_PROFILE:-secrets}）"
