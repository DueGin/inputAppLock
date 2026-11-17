#!/usr/bin/env bash
# 把 build/InputLock.app 打成「双击打开 → 拖进 Applications」的 macOS DMG 安装镜像。
#
# 用法：
#   ./scripts/make_dmg.sh                       # 版本号取自 build/InputLock.app 的 Info.plist
#   VERSION=1.0.1 ./scripts/make_dmg.sh         # 显式指定版本号（产物名与卷名都用它）
#   UNIVERSAL=1 VERSION=1.0.1 ./scripts/build_app.sh && VERSION=1.0.1 ./scripts/make_dmg.sh
#
# 可选环境变量：
#   VERSION=x.y.z     版本号；缺省读 .app 内 CFBundleShortVersionString（前缀 v 自动去掉）
#   APP_BUNDLE=path   指定要打包的 .app，默认 build/InputLock.app
#   VOL_NAME=name     卷名，默认 "InputLock <version>"
#   DMG_FORMAT=UDZO   hdiutil convert 输出格式，默认 UDZO（可换 ULFO，压缩率更高）
#   DMG_FS=HFS+       镜像文件系统，默认 HFS+（老系统兼容性最好）
#   FINDER_LAYOUT=0   跳过 Finder 窗口布局（CI / 无 GUI 会话会自动跳过）
#   SKIP_VERIFY=1     跳过最后一步的挂载校验（平时别关）
#
# 产物（只写 build/）：
#   build/InputLock-<version>.dmg
#   build/InputLock-<version>.dmg.sha256
#
# 只依赖系统自带工具：hdiutil / ditto / codesign / shasum / PlistBuddy，
# SetFile 与 osascript 属可选项，缺了或失败都只跳过、不中断构建。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="InputLock"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="${APP_BUNDLE:-$BUILD_DIR/$APP_NAME.app}"
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ICON_SOURCE="$ROOT/Resources/AppIcon.icns"

DMG_FORMAT="${DMG_FORMAT:-UDZO}"
DMG_FS="${DMG_FS:-HFS+}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"

die() { echo "!! $*" >&2; exit 1; }
warn() { echo "!! $*" >&2; }

# ---------------------------------------------------------------- 前置检查

[[ -d "$APP_BUNDLE" ]] || die "找不到 $APP_BUNDLE，先跑 ./scripts/build_app.sh"
[[ -f "$APP_BIN" ]] || die "找不到可执行文件 $APP_BIN"
[[ -f "$APP_PLIST" ]] || die "找不到 $APP_PLIST"

VERSION="${VERSION:-}"
VERSION="${VERSION#v}"                       # 允许直接传 v1.2.3
if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
fi
[[ -n "$VERSION" ]] || die "解析不到版本号：请传 VERSION=x.y.z 或检查 $APP_PLIST"

VOL_NAME="${VOL_NAME:-$APP_NAME $VERSION}"
DMG_BASENAME="$APP_NAME-$VERSION.dmg"
OUT_DMG="$BUILD_DIR/$DMG_BASENAME"
OUT_SHA="$OUT_DMG.sha256"

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- 临时目录 + 清理

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"                 # macOS 的 TMPDIR 带结尾斜杠，去掉免得路径里出现 //
SCRATCH="$(mktemp -d "$TMP_BASE/inputlock-dmg.XXXXXX")"
STAGING="$SCRATCH/staging"
RW_DMG="$SCRATCH/rw.dmg"
VERIFY_MNT="$SCRATCH/verify-mnt"
LAYOUT_MNT=""
VERIFY_MOUNTED=0

cleanup() {
    local status=$?
    set +e
    if [[ "$VERIFY_MOUNTED" == "1" && -n "$VERIFY_MNT" ]]; then
        hdiutil detach "$VERIFY_MNT" -quiet 2>/dev/null \
            || hdiutil detach "$VERIFY_MNT" -force -quiet 2>/dev/null
    fi
    if [[ -n "$LAYOUT_MNT" ]]; then
        hdiutil detach "$LAYOUT_MNT" -quiet 2>/dev/null \
            || hdiutil detach "$LAYOUT_MNT" -force -quiet 2>/dev/null
    fi
    [[ -d "$SCRATCH" ]] && rm -rf "$SCRATCH"
    return $status
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 同一卷名可能被上一次失败的构建占着，先摘掉，否则 hdiutil 会把卷名改成 "xxx 1"。
if [[ -d "/Volumes/$VOL_NAME" ]]; then
    echo "==> 卸载残留卷 /Volumes/$VOL_NAME"
    hdiutil detach "/Volumes/$VOL_NAME" -quiet 2>/dev/null \
        || hdiutil detach "/Volumes/$VOL_NAME" -force -quiet 2>/dev/null || true
fi

# ---------------------------------------------------------------- staging

echo "==> 组装 staging：$APP_NAME.app + Applications 快捷方式"
mkdir -p "$STAGING"
# ditto 复制保留签名所需的文件权限与扩展属性；cp -R 在部分情况下会丢掉 xattr。
ditto "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# ---------------------------------------------------------------- 创建可写镜像

echo "==> 创建可写镜像（$DMG_FS，卷名「$VOL_NAME」）"
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOL_NAME" \
    -fs "$DMG_FS" \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null

# ---------------------------------------------------------------- 挂载 + 卷图标 + Finder 布局

echo "==> 挂载可写镜像"
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -noautoopen -noverify)"
LAYOUT_MNT="$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ -n "$LAYOUT_MNT" && -d "$LAYOUT_MNT" ]] || die "挂载可写镜像失败：$ATTACH_OUT"
echo "    挂载点：$LAYOUT_MNT"

# Finder 窗口布局：只有图形登录会话里才可能成功；CI / SSH / 无 Finder 时直接跳过，
# 并且用超时兜底，避免 Automation 授权弹窗把整个构建卡死。
have_gui_session() {
    [[ "${FINDER_LAYOUT:-auto}" == "0" ]] && return 1
    [[ "${CI:-}" == "true" ]] && return 1
    [[ "$(launchctl managername 2>/dev/null || true)" == "Aqua" ]] || return 1
    command -v osascript >/dev/null 2>&1
}

# 在后台跑命令并限时；超时或失败都只返回非零，不抛错。
run_with_timeout() {
    local secs="$1"; shift
    "$@" & local pid=$!
    local ticks=0 limit=$((secs * 10))
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= limit )); then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

apply_finder_layout() {
    local mount_path="$1"
    local disk_name
    disk_name="$(basename "$mount_path")"
    local script_file="$SCRATCH/finder-layout.applescript"
    cat > "$script_file" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    tell application "Finder"
        tell disk diskName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 160, 780, 560}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set position of item "InputLock.app" of container window to {150, 215}
            set position of item "Applications" of container window to {430, 215}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
end run
APPLESCRIPT
    run_with_timeout 25 osascript "$script_file" "$disk_name"
}

if have_gui_session; then
    echo "==> 尝试用 Finder 设置窗口大小与图标位置（失败会自动跳过）"
    if apply_finder_layout "$LAYOUT_MNT"; then
        echo "    窗口布局已写入 .DS_Store"
        sync
    else
        warn "Finder 布局失败或超时（无 Automation 授权 / 无 Finder），已跳过；安装不受影响"
    fi
else
    echo "==> 无 GUI 会话或 FINDER_LAYOUT=0，跳过 Finder 窗口布局"
fi

# 卷图标要放在 Finder 布局之后：Finder 打开可写卷时会自己「管理」卷根里的
# .VolumeIcon.icns（实测会被删掉），所以布局写完再放图标、再打自定义图标位。
if [[ -f "$ICON_SOURCE" ]]; then
    echo "==> 设置卷图标"
    cp "$ICON_SOURCE" "$LAYOUT_MNT/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$LAYOUT_MNT" || warn "SetFile -a C 失败，卷图标可能不显示（不影响安装）"
    else
        warn "系统没有 SetFile（需要 Xcode Command Line Tools），跳过「自定义图标」属性"
    fi
else
    warn "找不到卷图标源文件 $ICON_SOURCE，卷图标将使用系统默认图标"
fi

echo "==> 卸载可写镜像"
sync
# 挂载期间 fseventsd 会在卷根建 .fseventsd，卸之前清掉，免得用户打开 dmg 看到垃圾目录。
rm -rf "$LAYOUT_MNT/.fseventsd" 2>/dev/null || true
hdiutil detach "$LAYOUT_MNT" -quiet 2>/dev/null \
    || hdiutil detach "$LAYOUT_MNT" -force -quiet 2>/dev/null \
    || warn "卸载 $LAYOUT_MNT 失败，继续"
LAYOUT_MNT=""

# ---------------------------------------------------------------- 转成压缩只读镜像

echo "==> 转换为 $DMG_FORMAT"
rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format "$DMG_FORMAT" -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null
[[ -f "$OUT_DMG" ]] || die "生成 $OUT_DMG 失败"

# ---------------------------------------------------------------- 给 dmg 本身签名

echo "==> ad-hoc 签名 dmg"
codesign --force --sign - "$OUT_DMG"
codesign --verify --verbose=2 "$OUT_DMG" 2>&1 | sed 's/^/    /' || warn "dmg 签名校验未通过（ad-hoc 可忽略）"

# ---------------------------------------------------------------- 校验

if [[ "$SKIP_VERIFY" == "1" ]]; then
    echo "==> SKIP_VERIFY=1，跳过 hdiutil verify 与挂载校验"
else
    echo "==> hdiutil verify"
    hdiutil verify "$OUT_DMG" 2>&1 | tail -3 | sed 's/^/    /'

    echo "==> 挂载校验（只读）"
    mkdir -p "$VERIFY_MNT"
    hdiutil attach "$OUT_DMG" -nobrowse -noautoopen -noverify -readonly -mountpoint "$VERIFY_MNT" >/dev/null
    VERIFY_MOUNTED=1

    echo "--- 挂载后的目录列表 ---"
    ls -la "$VERIFY_MNT" | sed 's/^/    /'

    [[ -d "$VERIFY_MNT/$APP_NAME.app" ]] || die "dmg 里没有 $APP_NAME.app"
    [[ -L "$VERIFY_MNT/Applications" ]] || die "dmg 里没有 Applications 快捷方式"
    LINK_TARGET="$(readlink "$VERIFY_MNT/Applications")"
    [[ "$LINK_TARGET" == "/Applications" ]] || die "Applications 快捷方式指向 $LINK_TARGET，应为 /Applications"

    # 拷出到临时目录再验签，模拟用户从只读卷拖进 /Applications 的效果。
    ditto "$VERIFY_MNT/$APP_NAME.app" "$SCRATCH/installed-$APP_NAME.app"
    echo "--- codesign --verify --deep --strict ---"
    codesign --verify --deep --strict --verbose=2 "$SCRATCH/installed-$APP_NAME.app" 2>&1 | sed 's/^/    /'
    echo "--- lipo -archs ---"
    lipo -archs "$SCRATCH/installed-$APP_NAME.app/Contents/MacOS/$APP_NAME" | sed 's/^/    /'
    echo "--- 版本 ---"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$SCRATCH/installed-$APP_NAME.app/Contents/Info.plist" | sed 's/^/    /'

    hdiutil detach "$VERIFY_MNT" -quiet \
        || hdiutil detach "$VERIFY_MNT" -force -quiet \
        || warn "卸载校验挂载点 $VERIFY_MNT 失败（cleanup 里会重试）"
    VERIFY_MOUNTED=0
fi

# ---------------------------------------------------------------- sha256（最后算，前面步骤都会改文件）

echo "==> 生成 sha256"
( cd "$BUILD_DIR" && shasum -a 256 "$DMG_BASENAME" | tee "$DMG_BASENAME.sha256" ) | sed 's/^/    /'

echo ""
echo "==> 完成：$OUT_DMG"
echo "    卷名：$VOL_NAME"
echo "    大小：$(du -h "$OUT_DMG" | awk '{print $1}')（$(stat -f%z "$OUT_DMG") 字节）"
echo "    架构：$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || echo '?')"
echo "    校验：$OUT_SHA"
echo "    试装：open \"$OUT_DMG\"   # 打开后把 $APP_NAME 拖到 Applications"
