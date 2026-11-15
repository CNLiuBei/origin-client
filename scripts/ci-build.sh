#!/bin/zsh
# 不用开发者证书编译 iPhone 与 Mac 版，打包到 build/dist。GitHub Actions 和本机都用它。
#   scripts/ci-build.sh          两个都编
#   scripts/ci-build.sh ios      只编 iPhone / iPad
#   scripts/ci-build.sh mac      只编 Mac
#
# iPhone 版是未签名的 IPA，需要用爱思助手、Sideloadly、AltStore 等工具签名安装。
# Mac 版是本地签名（ad-hoc）的通用版，第一次打开要在“系统设置 → 隐私与安全性”里点“仍要打开”。
set -euo pipefail
cd "$(dirname "$0")/.."

target=${1:-all}
build_number=${BUILD_NUMBER:-$(date +%y%m%d%H%M)}
dist=build/dist
mkdir -p "$dist"
[[ -d Origin.xcodeproj ]] || xcodegen generate

compile() {
    local scheme=$1 destination=$2 data=$3
    xcodebuild \
        -project Origin.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -destination "$destination" \
        -derivedDataPath "$data" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        CURRENT_PROJECT_VERSION="$build_number" \
        build
}

if [[ $target == all || $target == ios ]]; then
    echo "编译 iPhone 版…"
    compile Origin "generic/platform=iOS" build/ci-ios
    app=build/ci-ios/Build/Products/Release-iphoneos/Origin.app
    staging=$(mktemp -d)
    mkdir -p "$staging/Payload"
    ditto "$app" "$staging/Payload/Origin.app"
    rm -f "$dist/Origin-iOS.ipa"
    (cd "$staging" && zip -qry "$OLDPWD/$dist/Origin-iOS.ipa" Payload)
    rm -rf "$staging"
    echo "已生成 $dist/Origin-iOS.ipa"
fi

if [[ $target == all || $target == mac ]]; then
    echo "编译 Mac 版…"
    compile OriginMac "generic/platform=macOS" build/ci-mac
    app=build/ci-mac/Build/Products/Release/Origin.app
    # 钥匙串访问组需要描述文件，本地签名用不了，其余权限照旧
    entitlements=$(mktemp).plist
    cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
PLIST
    codesign --force --deep --sign - --entitlements "$entitlements" "$app"
    rm -f "$entitlements"
    rm -f "$dist/Origin-macOS.zip"
    ditto -c -k --keepParent "$app" "$dist/Origin-macOS.zip"
    echo "已生成 $dist/Origin-macOS.zip"
fi
