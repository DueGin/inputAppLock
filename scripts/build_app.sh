#!/usr/bin/env bash
# 构建 InputLock.app（ad-hoc 签名，本机自用 / CI 发版共用）
#
# 用法：
#   ./scripts/build_app.sh                 # release 构建，只编译当前架构
#   ./scripts/build_app.sh debug           # debug 构建
#   UNIVERSAL=1 ./scripts/build_app.sh     # arm64 + x86_64 通用二进制
#
# 环境变量（可选，本地默认行为不变）：
#   UNIVERSAL=1     构建 arm64 + x86_64 通用二进制（CI 发版用）
#   VERSION=x.y.z   写入 .app 内 Info.plist 的 CFBundleShortVersionString；
#                   前缀 v 会被去掉（v1.2.3 -> 1.2.3），源 Resources/Info.plist 不动
#   BUILD_NUMBER    写入 CFBundleVersion；缺省取 GITHUB_RUN_NUMBER，再缺省取 VERSION
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP_NAME="InputLock"
CONFIG="${1:-release}"
BUILD_DIR="${ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_PLIST="${APP_BUNDLE}/Contents/Info.plist"

UNIVERSAL="${UNIVERSAL:-0}"
VERSION="${VERSION:-}"
VERSION="${VERSION#v}"                       # 允许直接传 v1.2.3
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"

# 写字符串到 plist；键不存在时自动补一个（源 Info.plist 少了键也能兜住）
plist_set() {
    local key="$1" value="$2" plist="$3"
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist}"
}

# SwiftPM 的 --arch 多架构构建依赖完整 Xcode 里的 xcbuild；只有 Command Line Tools
# 时会报 "xcbuild executable ... does not exist"。这种情况下回退到分架构编译 + lipo，
# 保证本地（CLT-only）也能出通用二进制。
have_full_xcode() { xcodebuild -version >/dev/null 2>&1; }

BIN_PATH=""
if [[ "${UNIVERSAL}" == "1" ]]; then
    if have_full_xcode; then
        echo "==> swift build -c ${CONFIG} --arch arm64 --arch x86_64"
        swift build -c "${CONFIG}" --arch arm64 --arch x86_64
        BIN_PATH="$(swift build -c "${CONFIG}" --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
    else
        echo "==> 未检测到完整 Xcode（仅 Command Line Tools），回退：分架构编译 + lipo 合并"
        swift build -c "${CONFIG}"
        ARM_BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
        swift build -c "${CONFIG}" --triple x86_64-apple-macosx13.0
        X86_BIN="$(swift build -c "${CONFIG}" --triple x86_64-apple-macosx13.0 --show-bin-path)/${APP_NAME}"
        for bin in "${ARM_BIN}" "${X86_BIN}"; do
            if [[ ! -f "${bin}" ]]; then
                echo "!! 找不到可执行文件：${bin}" >&2
                exit 1
            fi
        done
        mkdir -p "${BUILD_DIR}/universal"
        BIN_PATH="${BUILD_DIR}/universal/${APP_NAME}"
        lipo -create -output "${BIN_PATH}" "${ARM_BIN}" "${X86_BIN}"
        echo "==> lipo 合并完成：$(lipo -archs "${BIN_PATH}")"
    fi
else
    echo "==> swift build -c ${CONFIG}"
    swift build -c "${CONFIG}"
    BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
fi

if [[ ! -f "${BIN_PATH}" ]]; then
    echo "!! 找不到可执行文件：${BIN_PATH}" >&2
    exit 1
fi

echo "==> 组装 ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP_PLIST}"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# 版本号只写进打好的 .app，源 Resources/Info.plist 保持占位版本不动。
if [[ -n "${VERSION}" ]]; then
    PLIST_BUILD_NUMBER="${BUILD_NUMBER:-${VERSION}}"
    echo "==> 写入版本：CFBundleShortVersionString=${VERSION} CFBundleVersion=${PLIST_BUILD_NUMBER}"
    plist_set CFBundleShortVersionString "${VERSION}" "${APP_PLIST}"
    plist_set CFBundleVersion "${PLIST_BUILD_NUMBER}" "${APP_PLIST}"
fi

echo "==> 复制图标资源"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
ICON_SOURCE="${ROOT}/Resources/AppIcon.icns"
if [[ ! -f "${ICON_SOURCE}" ]]; then
    echo "!! 找不到 App 图标：${ICON_SOURCE}" >&2
    exit 1
fi
cp "${ICON_SOURCE}" "${RESOURCES_DIR}/AppIcon.icns"

# 菜单栏 template 图标（1x + @2x）。设计源文件在 assets/logo/menubar/，只复制 PNG，SVG 不进包。
MENUBAR_SOURCE="${ROOT}/assets/logo/menubar"
for icon in MenuBarIconTemplate MenuBarIconSecureTemplate MenuBarIconDisabledTemplate; do
    for scale in ".png" "@2x.png"; do
        src="${MENUBAR_SOURCE}/${icon}${scale}"
        if [[ ! -f "${src}" ]]; then
            echo "!! 缺少菜单栏图标：${src}" >&2
            exit 1
        fi
        cp "${src}" "${RESOURCES_DIR}/"
    done
done

# ad-hoc 签名。CI 里同样是 ad-hoc（不引入证书 secrets），所以产物未经公证，
# 首次打开需要用户手动放行 Gatekeeper（见 README「下载安装」）。
# 将来接 Developer ID + 公证时，把下面这行换成带 --options runtime 的正式签名，
# 再补 notarytool submit / stapler staple 两步即可，无需改动其它逻辑。
echo "==> ad-hoc 签名"
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --verbose=2 "${APP_BUNDLE}" || echo "!! codesign 校验未通过（ad-hoc 签名可忽略部分警告）"

# 资源与签名都写入后刷新一次 bundle 时间戳，让 Finder 重新读取 App 图标缓存。
touch "${APP_BUNDLE}"

echo ""
echo "==> 完成：${APP_BUNDLE}"
echo "    版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PLIST}") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PLIST}"))"
echo "    架构：$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}")"
echo "    运行：open \"${APP_BUNDLE}\""
echo "    安装：cp -R \"${APP_BUNDLE}\" /Applications/ 然后 open /Applications/${APP_NAME}.app"
echo "    打 dmg：VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PLIST}") ./scripts/make_dmg.sh   # 发版用的拖拽安装镜像"
