#!/bin/zsh
# 把 Origin 重新签名并装到已连接的 iPhone。
# 免费 Apple ID 的开发描述文件 7 天后失效，到期后解锁手机、插上线，再跑一次本脚本。
# 付费开发者账号的有效期更长，脚本结束时会打印这份描述文件的真实失效时间。
#
# 使用本机钥匙串里的 Apple ID。别人的团队会自动换成自己的 Bundle ID。
#   scripts/install-iphone.sh
#   DEVICE="手机名字" scripts/install-iphone.sh
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/install-iphone.sh
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

devices_json=$(mktemp)
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" --quiet

device_line=$(python3 - "$devices_json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
want = os.environ.get("DEVICE", "").strip()
found = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties") or {}
    if hardware.get("platform") != "iOS":
        continue
    props = device.get("deviceProperties") or {}
    link = device.get("connectionProperties") or {}
    found.append({
        "name": props.get("name") or "",
        "udid": hardware.get("udid") or "",
        "tunnel": link.get("tunnelState") or "",
    })
if want:
    found = [item for item in found if item["udid"] == want or item["name"] == want]
    if not found:
        sys.exit(f"找不到设备：{want}")
else:
    ready = [item for item in found if item["tunnel"] == "connected"]
    if ready:
        found = ready
    elif len(found) > 1:
        print("连着多台 iPhone，请用 DEVICE=名字 指定一台：", file=sys.stderr)
        for item in found:
            print(f"  {item['name']}  {item['udid']}  {item['tunnel']}", file=sys.stderr)
        sys.exit(2)
if not found:
    sys.exit("没有发现 iPhone。请解锁手机，用数据线连上这台 Mac，并点“信任”。")
item = found[0]
print(f"{item['name']}\t{item['udid']}\t{item['tunnel']}")
PY
)
name=${device_line%%$'\t'*}
rest=${device_line#*$'\t'}
udid=${rest%%$'\t'*}
tunnel=${rest##*$'\t'}
echo "安装到 ${name}"

build_log=$(mktemp)
file_count=$(find Origin -name '*.swift' | wc -l | tr -d ' ')
if ! PROGRESS_FILES="$file_count" python3 scripts/progress.py compile "$build_log" \
    xcodebuild \
    -project Origin.xcodeproj \
    -scheme Origin \
    -configuration Debug \
    -destination "platform=iOS,id=${udid}" \
    -derivedDataPath build/iphone \
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

app="build/iphone/Build/Products/Debug-iphoneos/Origin.app"
if [[ ! -d $app ]]; then
    echo "没有找到 ${app}" >&2
    exit 1
fi

install_log=$(mktemp)
if ! python3 scripts/progress.py install "$install_log" \
    xcrun devicectl device install app --device "$udid" "$app"
then
    echo "安装失败。请解锁手机，用数据线连上这台 Mac，并点“信任”。" >&2
    tail -n 20 "$install_log" >&2
    rm -f "$install_log"
    exit 1
fi
rm -f "$install_log"
# 编译出来的 .app 会被系统登记成 Mac 上的应用，出现在启动台里
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true

profile=$(find "$app" -name embedded.mobileprovision -print -quit)
if [[ -n $profile ]]; then
    plist=$(mktemp)
    security cms -D -i "$profile" -o "$plist" >/dev/null
    expires=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist")
    rm -f "$plist"
    echo "安装完成。签名到期：${expires}"
    echo "到期后重新双击「安装到 iPhone」。"
else
    echo "安装完成。到期后重新双击「安装到 iPhone」。"
fi

xcrun devicectl device process launch --device "$udid" "$SIGN_BUNDLE" >/dev/null
echo "已在手机上打开 Origin。"
