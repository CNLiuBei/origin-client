#!/bin/zsh
# 编译 macOS 版 Origin，替换本机已安装的副本并打开。
# 旧的 /Applications/Origin.app 不会自己更新，改完代码后重新运行本脚本。
#
# 使用本机钥匙串里的 Apple ID。别人的团队会自动换成自己的 Bundle ID。
#   scripts/install-mac.sh
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/install-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
sign_resolve

if [[ ! -d Origin.xcodeproj ]]; then
    if [[ ! -d Vendor/KSPlayer ]]; then
        echo "还没有 Xcode 工程。先运行 scripts/bootstrap.sh" >&2
        exit 1
    fi
    xcodegen generate
fi

build_log=$(mktemp)
file_count=$(find Origin OriginMac -name '*.swift' | wc -l | tr -d ' ')
if ! PROGRESS_FILES="$file_count" python3 scripts/progress.py compile "$build_log" \
    xcodebuild \
    -project Origin.xcodeproj \
    -scheme OriginMac \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/mac \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$SIGN_TEAM" \
    PRODUCT_BUNDLE_IDENTIFIER="$SIGN_BUNDLE" \
    CURRENT_PROJECT_VERSION="$(date +%y%m%d%H%M)" \
    CODE_SIGN_STYLE=Automatic \
    build
then
    echo "编译失败：" >&2
    tail -n 30 "$build_log" >&2
    rm -f "$build_log"
    exit 1
fi
rm -f "$build_log"

app="build/mac/Build/Products/Debug/Origin.app"
if [[ ! -d $app ]]; then
    echo "没有找到 ${app}" >&2
    exit 1
fi

if [[ -w /Applications ]]; then
    dest="/Applications/Origin.app"
else
    mkdir -p "$HOME/Applications"
    dest="$HOME/Applications/Origin.app"
fi

if pgrep -xq Origin; then
    osascript -e 'tell application "Origin" to quit' || true
    for _ in {1..25}; do
        pgrep -xq Origin || break
        sleep 0.2
    done
fi

rm -rf "$dest"
ditto "$app" "$dest"
echo "已安装到 ${dest}"

# 编译目录里的副本也带同一个 Bundle ID。系统按 Bundle ID 读 Info.plist（比如局域网服务权限），
# 只登记安装的这份，免得读到旧副本
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -u "$app" 2>/dev/null || true
"$lsregister" -f "$dest" 2>/dev/null || true

open "$dest"
