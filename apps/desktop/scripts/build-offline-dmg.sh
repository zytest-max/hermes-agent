#!/usr/bin/env bash
#
# build-offline-dmg.sh — 自包含离线 Hermes 桌面端打包流程(fork 维护脚本)
#
# 流程: 拉代码 → 合并官方 → 校验我们的改动项 → 同步版本 → stage 运行时
#       → 类型检查 → 打 dmg
#
# 设计要点:
#   - 合并冲突时【停下】并打印冲突文件,需人工解决后重跑(脚本不会瞎合)。
#   - 每次都校验"改动项"(我们的补丁)是否还在,被官方覆盖就停下。
#   - 前端包版本【自动跟随后端】(pyproject.toml 的 version)。
#   - Python 依赖没变就复用已装的 site-packages;变了才重建 venv(清华镜像)。
#   - 全程走国内镜像(npm/electron/electron-builder/pypi),不卡下载。
#
# 用法:
#   bash apps/desktop/scripts/build-offline-dmg.sh            # 完整流程
#   bash apps/desktop/scripts/build-offline-dmg.sh --no-merge # 跳过拉取/合并,只打包
#
set -euo pipefail

# ── 路径 ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"   # apps/desktop/scripts → 仓库根
DESKTOP="$REPO_ROOT/apps/desktop"
STAGE="$DESKTOP/build/hermes-runtime"
BRANCH="feat/self-contained-offline-dmg"

# ── 国内镜像 ────────────────────────────────────────────────────────────────
export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
export ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/"
export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
export CSC_IDENTITY_AUTO_DISCOVERY=false

UV="${UV:-$HOME/.local/bin/uv}"

# ── 改动项(我们的补丁)+ 必须存在的标记 ────────────────────────────────────
# 合并后逐项校验这些标记是否还在;缺了就说明被官方覆盖,停下让人处理。
declare -a OUR_FILES=(
  "apps/desktop/electron/main.cjs"
  "apps/desktop/scripts/after-pack.cjs"
  "apps/desktop/scripts/build-offline-dmg.sh"
  "apps/desktop/package.json"
  "apps/desktop/assets/icon.icns"
  "hermes_cli/inventory.py"
  ".gitignore"
)
declare -a MARKER_FILES=(
  "apps/desktop/electron/main.cjs"
  "apps/desktop/scripts/after-pack.cjs"
  "apps/desktop/package.json"
  "hermes_cli/inventory.py"
)
declare -a MARKER_TEXTS=(
  "installBundledRuntime"
  "deep ad-hoc"
  "hermes-runtime"
  "Self-heal a"
)

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXX %s\033[0m\n' "$*" >&2; exit 1; }

DO_MERGE=1
[ "${1:-}" = "--no-merge" ] && DO_MERGE=0

cd "$REPO_ROOT"

# ── 0. 前置检查 ──────────────────────────────────────────────────────────────
command -v node >/dev/null || die "缺 node"
[ -x "$UV" ] || die "缺 uv ($UV)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "不是 git 仓库"

# 工作区必须干净(忽略 .gitignore 里的产物);否则合并/打包会出乱子。
if [ -n "$(git status --porcelain | grep -vE '^\?\?')" ]; then
  warn "工作区有未提交的【已跟踪】改动:"
  git status --short | grep -vE '^\?\?' || true
  die "请先提交或暂存,再跑本脚本。"
fi

# ── 1. 切到我们的分支 ────────────────────────────────────────────────────────
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CUR_BRANCH" != "$BRANCH" ]; then
  log "切换到分支 $BRANCH"
  git checkout "$BRANCH"
fi

# ── 2 & 3. 拉取 + 合并官方 ───────────────────────────────────────────────────
if [ "$DO_MERGE" = "1" ]; then
  log "拉取官方 upstream/main"
  git fetch upstream main

  BEFORE="$(git rev-parse HEAD)"
  log "合并 upstream/main"
  if ! git merge --no-edit upstream/main; then
    warn "合并冲突,冲突文件如下:"
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo
    warn "脚本已停。请人工解决冲突(尤其留意下面这些改动项),解决并 commit 后,"
    warn "用 --no-merge 重跑本脚本即可继续打包:"
    printf '    %s\n' "${OUR_FILES[@]}"
    exit 2
  fi
  AFTER="$(git rev-parse HEAD)"
  if [ "$BEFORE" != "$AFTER" ]; then
    log "已合并新提交: $BEFORE → $AFTER"
  else
    log "已是最新,无新提交"
  fi
fi

# ── 4. 校验改动项是否幸存 ────────────────────────────────────────────────────
log "校验改动项(我们的补丁是否还在)"
for i in "${!MARKER_FILES[@]}"; do
  f="${MARKER_FILES[$i]}"; t="${MARKER_TEXTS[$i]}"
  if grep -q "$t" "$f"; then
    printf '    ✅ %s\n' "$f"
  else
    warn "改动项可能被官方覆盖: $f 缺少标记 '$t'"
    die "请人工恢复该补丁后,用 --no-merge 重跑。"
  fi
done

# ── 5. 前端版本跟随后端 ──────────────────────────────────────────────────────
BACKEND_VER="$(grep -m1 '^version' "$REPO_ROOT/pyproject.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$BACKEND_VER" ] || die "读不到后端版本 (pyproject.toml)"
DESKTOP_VER="$(node -e "console.log(require('$DESKTOP/package.json').version)")"
if [ "$DESKTOP_VER" != "$BACKEND_VER" ]; then
  log "同步前端版本 $DESKTOP_VER → $BACKEND_VER(跟随后端)"
  node -e "const fs=require('fs');const p='$DESKTOP/package.json';const j=JSON.parse(fs.readFileSync(p));j.version='$BACKEND_VER';fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n')"
  git add "$DESKTOP/package.json"
  git commit -q -m "chore(desktop): sync app version to backend $BACKEND_VER"
else
  log "前端版本已等于后端 ($BACKEND_VER)"
fi

# ── 6. 确保 node 依赖就绪 ────────────────────────────────────────────────────
if [ ! -x "$REPO_ROOT/node_modules/.bin/electron-builder" ]; then
  log "安装 node 依赖(workspace, 国内镜像)"
  npm install --workspace apps/desktop --registry=https://registry.npmmirror.com
fi

# ── 7. stage 运行时:源码(每次刷)+ python/site-packages(按需重建)──────────
log "stage 运行时源码(来自当前工作树)"
mkdir -p "$STAGE/source"
rsync -a --delete \
  --exclude='.git' --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='node_modules' --exclude='release' --exclude='dist' \
  --exclude='build/hermes-runtime' --exclude='.hermes-bootstrap-complete' \
  --filter='protect hermes-runtime' \
  "$REPO_ROOT/" "$STAGE/source/"
[ -f "$STAGE/source/hermes_cli/main.py" ] || die "stage 的源码不完整(缺 hermes_cli/main.py)"
git rev-parse HEAD > "$STAGE/COMMIT"
git rev-parse --abbrev-ref HEAD > "$STAGE/BRANCH"

# 依赖指纹:pyproject + uv.lock 变了才重建 venv,否则复用已装的 site-packages。
DEPS_HASH="$(cat "$REPO_ROOT/pyproject.toml" "$REPO_ROOT/uv.lock" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
STORED_HASH="$(cat "$STAGE/.deps-hash" 2>/dev/null || echo '')"
if [ ! -x "$STAGE/python/bin/python3.11" ] || [ ! -d "$STAGE/site-packages" ] || [ "$DEPS_HASH" != "$STORED_HASH" ]; then
  log "重建运行时依赖(首次 / 依赖有变)— 清华镜像,可能几分钟"
  TMPV="$(mktemp -d)"
  "$UV" venv "$TMPV/venv" --python 3.11 >/dev/null
  ( cd "$REPO_ROOT" && VIRTUAL_ENV="$TMPV/venv" UV_PYTHON="$TMPV/venv/bin/python" "$UV" pip install -e '.[all]' >/dev/null )
  # 把 uv 管理的 standalone python 整体打包(脱离开发机也能跑)
  PYBIN="$("$UV" python find 3.11)"
  PYBASE="$(cd "$(dirname "$PYBIN")/.." && pwd)"
  rsync -a --delete "$PYBASE/" "$STAGE/python/"
  rsync -a --delete "$TMPV/venv/lib/python3.11/site-packages/" "$STAGE/site-packages/"
  echo "$DEPS_HASH" > "$STAGE/.deps-hash"
  rm -rf "$TMPV"
  log "运行时依赖已重建 ($(ls "$STAGE/site-packages" | wc -l | tr -d ' ') 个包)"
else
  log "依赖未变,复用已装 site-packages ($(du -sh "$STAGE/site-packages" | cut -f1))"
fi

# ── 8. 类型检查(早失败)──────────────────────────────────────────────────────
log "类型检查"
( cd "$DESKTOP" && npm run type-check )

# ── 9. 构建 + 打包 ───────────────────────────────────────────────────────────
log "构建渲染层 + 打 dmg"
export GITHUB_SHA="$(git rev-parse HEAD)"
export GITHUB_REF_NAME="$(git rev-parse --abbrev-ref HEAD)"
cd "$DESKTOP"
rm -f release/*.dmg release/*.blockmap 2>/dev/null || true
npm run build
npm run builder -- --mac

DMG="$DESKTOP/release/Hermes-$BACKEND_VER-mac-arm64.dmg"
echo
if [ -f "$DMG" ]; then
  log "✅ 打包完成"
  ls -lah "$DMG" | awk '{print "    "$9"  "$5}'
  shasum -a 256 "$DMG" | awk '{print "    SHA256: "$1}'
  echo "    安装后首次打开需破一次 Gatekeeper: xattr -cr /Applications/Hermes.app"
else
  die "没找到产物 dmg($DMG)"
fi
