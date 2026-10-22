#!/bin/bash
set -o pipefail
# ============================================
#  版本戳.command —— 把「git 提交数 = 构建号」写进 3 处版本戳并提交
#
#  本仓库的版本戳惯例是「构建号 = 代码提交的 git 提交数」，需要同步 3 个文件：
#    · ATV-Bilibili/BuildInfo.swift            (buildNumber / marketingVersion / commitHash)
#    · ATV-Bilibili/Supporting Files/Info.plist (CFBundleVersion)
#    · TopShelf/Info.plist                      (CFBundleVersion)
#  手工抄三处容易漏、容易写错，本脚本一次做完并自检。
#
#  批次节奏（每个功能批次两笔提交，本脚本只负责第二笔）：
#    1) 先提交代码批次              → 该提交的编号 N = git rev-list --count HEAD
#    2) 再跑本脚本                  → 把 N 写进上面 3 处并提交（编号 N+1）
#  所以工作区还有未提交改动时本脚本会拒绝运行 —— 那样算出来的编号必然不是本批的。
#
#  用法:
#    双击                          用默认提交信息
#    ./版本戳.command "批次主题"    提交信息带上主题
#    ./版本戳.command --check      只打印将要写入的值与前置检查结果，不改文件
#    ./版本戳.command --force ...  跳过「工作区必须干净 / HEAD 不是版本戳」两项前置检查
# ============================================
cd "$(dirname "$0")" || exit 1

BUILD_INFO="ATV-Bilibili/BuildInfo.swift"
APP_PLIST="ATV-Bilibili/Supporting Files/Info.plist"
SHELF_PLIST="TopShelf/Info.plist"
STAMP_FILES=("$BUILD_INFO" "$APP_PLIST" "$SHELF_PLIST")

CHECK_ONLY=0
FORCE=0
THEME=""
for arg in "$@"; do
  case "$arg" in
    --check|-c) CHECK_ONLY=1 ;;
    --force|-f) FORCE=1 ;;
    *) [ -z "$THEME" ] && THEME="$arg" ;;
  esac
done

bad() { echo "  ✗ $*"; }

for f in "${STAMP_FILES[@]}"; do
  [ -f "$f" ] || { bad "找不到 $f —— 请在仓库根目录运行本脚本"; exit 1; }
done

# ── 1. 取值 ──
COUNT=$(git rev-list --count HEAD) || { bad "读不到 git 提交数（这里是 git 仓库吗？）"; exit 1; }
HASH=$(git rev-parse --short HEAD)
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST" 2>/dev/null)
[ -n "$VERSION" ] || { bad "读不出 $APP_PLIST 的 CFBundleShortVersionString"; exit 1; }
EXISTING=$(grep -oE 'buildNumber *= *[0-9]+' "$BUILD_INFO" | grep -oE '[0-9]+' | tail -1)

echo "▶ 1/4 取值"
echo "    版本    $VERSION"
echo "    构建号  $COUNT   （= 当前 git 提交数，应等于刚提交的代码批次编号）"
echo "    哈希    $HASH"
echo "    文件现值 $EXISTING"

# ── 2. 前置检查 ──
echo "▶ 2/4 前置检查"

if [ "$FORCE" = "1" ]; then
  echo "  ⚠ --force：跳过工作区与编号自洽检查"
else
  # 未提交（含未跟踪）的改动 = 代码批次还没提交，此时算出来的编号是上一批的
  DIRTY=$(git status --porcelain | sed 's/^...//')
  OTHER=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    skip=0
    for s in "${STAMP_FILES[@]}"; do
      [ "$f" = "$s" ] && skip=1
    done
    [ "$skip" = "0" ] && OTHER="${OTHER}      ${f}"$'\n'
  done <<< "$DIRTY"

  if [ -n "$OTHER" ]; then
    bad "工作区还有未提交的改动，现在算出来的构建号会是上一批的编号："
    printf '%s' "$OTHER"
    echo "      → 先把代码批次提交好，再跑本脚本"
    exit 1
  fi

  # 「刚打过戳」的识别：HEAD 本身就是上一笔版本戳提交时，文件里的编号必然等于 COUNT-1
  if [ -n "$EXISTING" ] && [ "$EXISTING" -ge $((COUNT - 1)) ]; then
    bad "没有新的代码批次：HEAD 看起来就是上一笔版本戳提交（文件里是 $EXISTING，HEAD 是 $COUNT）"
    echo "      → 先提交本批代码，或确认无新批次；确实要重打请加 --force"
    exit 1
  fi
  echo "  ✓ 工作区没有其它改动，且 HEAD 不是版本戳提交"
fi

if [ "$CHECK_ONLY" = "1" ]; then
  echo "▶ 3/4 --check：只报告，不写文件"
  echo "    将写入 $BUILD_INFO: marketingVersion=$VERSION buildNumber=$COUNT commitHash=$HASH"
  echo "    将写入两个 Info.plist: CFBundleShortVersionString=$VERSION CFBundleVersion=$COUNT"
  exit 0
fi

# ── 3. 写入 3 处版本戳 ──
echo "▶ 3/4 写入版本戳"
COUNT="$COUNT" HASH="$HASH" VERSION="$VERSION" perl -pi -e '
  s/^(\s*static let marketingVersion = ).*$/$1"$ENV{VERSION}"/;
  s/^(\s*static let buildNumber = ).*$/$1$ENV{COUNT}/;
  s/^(\s*static let commitHash = ).*$/$1"$ENV{HASH}"/;
' "$BUILD_INFO" || { bad "写 $BUILD_INFO 失败"; exit 1; }
echo "  ✓ $BUILD_INFO"

for p in "$APP_PLIST" "$SHELF_PLIST"; do
  plutil -replace CFBundleVersion -string "$COUNT" "$p" || { bad "写 $p 失败"; exit 1; }
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$p" || { bad "写 $p 失败"; exit 1; }
  echo "  ✓ $p"
done

# 自检：plist 合法性 + 三处编号回读一致（写错了就别提交）
for p in "$APP_PLIST" "$SHELF_PLIST"; do
  plutil -lint "$p" >/dev/null || { bad "$p 不是合法 plist，已中止（文件已被改动，请 git checkout 还原）"; exit 1; }
done
GOT_APP=$(plutil -extract CFBundleVersion raw "$APP_PLIST")
GOT_SHELF=$(plutil -extract CFBundleVersion raw "$SHELF_PLIST")
GOT_SWIFT=$(grep -oE 'buildNumber *= *[0-9]+' "$BUILD_INFO" | grep -oE '[0-9]+' | tail -1)
if [ "$GOT_APP" != "$COUNT" ] || [ "$GOT_SHELF" != "$COUNT" ] || [ "$GOT_SWIFT" != "$COUNT" ]; then
  bad "三处构建号不一致（App=$GOT_APP TopShelf=$GOT_SHELF BuildInfo=$GOT_SWIFT），已中止"
  exit 1
fi
echo "  ✓ 自检通过：三处构建号均为 $COUNT"

# ── 4. 只提交这 3 个文件 ──
echo "▶ 4/4 提交版本戳"
if git diff --quiet HEAD -- "${STAMP_FILES[@]}"; then
  echo "  ✓ 版本戳本来就是 $COUNT，无需提交"
else
  if [ -n "$THEME" ]; then
    MSG="文档: 版本戳 ${VERSION}(${COUNT})=${HASH} — 同步 BuildInfo 与双 target CFBundleVersion 至${THEME}批次"
  else
    MSG="文档: 版本戳 ${VERSION}(${COUNT})=${HASH} — 同步 BuildInfo 与双 target CFBundleVersion"
  fi
  git add -- "${STAMP_FILES[@]}" || { bad "git add 失败"; exit 1; }
  git commit -q -m "$MSG

Co-Authored-By: Claude Sonnet 4.6 noreply@anthropic.com" || { bad "git commit 失败"; exit 1; }
  echo "  ✓ 已提交：$MSG"
fi

echo
echo "  下一步：装机验证 ./本机-装机-双版本.command（或单独装某一版）"
[ -t 0 ] && read -n 1 -s -r -p "按任意键关闭..."
exit 0
