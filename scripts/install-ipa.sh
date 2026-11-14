#!/bin/zsh
# 把 IPA 用本机 Apple ID 重新签名后装到已连接的 iPhone。
# 免费账号的签名大约 7 天后失效，到期后对同一个 IPA 再运行一次。
#
#   scripts/install-ipa.sh App.ipa
#   scripts/install-ipa.sh            # 弹出选择文件窗口
#   DEVICE="手机名字" scripts/install-ipa.sh App.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
sign_resolve

ipa=${1:-}
if [[ -z $ipa ]]; then
    if [[ ! -t 0 ]]; then
        echo "用法：scripts/install-ipa.sh 文件.ipa" >&2
        exit 1
    fi
    ipa=$(osascript -e 'POSIX path of (choose file with prompt "选择要安装的 IPA")' || true)
    ipa=${ipa%$'\r'}
    [[ -n $ipa ]] || exit 1
fi
if [[ ! -f $ipa ]]; then
    echo "找不到 IPA：${ipa}" >&2
    exit 1
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
if [[ $tunnel != connected ]]; then
    echo "手机还没和对这台 Mac 建好开发连接。请保持解锁，并在手机上点“信任”。" >&2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"; rm -f "$devices_json"' EXIT
unzip -q "$ipa" -d "$work"
app=$(find "$work/Payload" -maxdepth 2 -name '*.app' -print -quit)
if [[ -z $app ]]; then
    echo "IPA 里没有 Payload/*.app" >&2
    exit 1
fi

binary="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
cryptid=$(otool -l "$binary" 2>/dev/null | awk '/cryptid/ {print $2; exit}')
if [[ $cryptid == 1 ]]; then
    echo "这是 App Store 下载的加密包，不能改签后安装。" >&2
    exit 1
fi

plan=$(python3 - "$app" "$SIGN_TEAM" "$udid" "$SIGN_BUNDLE" <<'PY'
import glob, os, plistlib, subprocess, sys
from datetime import datetime, timezone

app, team, udid, preferred = sys.argv[1:]
udid_norm = udid.replace("-", "").lower()

def cms(path):
    data = subprocess.check_output(["security", "cms", "-D", "-i", path])
    return plistlib.loads(data)

homes = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
]
profiles = []
for folder in homes:
    profiles.extend(glob.glob(os.path.join(folder, "*.mobileprovision")))

info = plistlib.loads(open(os.path.join(app, "Info.plist"), "rb").read())
bundle = info.get("CFBundleIdentifier")
if not bundle:
    sys.exit("IPA 没有 CFBundleIdentifier")

def device_ok(plist):
    devices = plist.get("ProvisionedDevices") or []
    if plist.get("ProvisionsAllDevices"):
        return True
    return any(item.replace("-", "").lower() == udid_norm for item in devices)

best = None
for path in profiles:
    try:
        plist = cms(path)
    except subprocess.CalledProcessError:
        continue
    teams = plist.get("TeamIdentifier") or []
    if team not in teams:
        continue
    expires = plist.get("ExpirationDate")
    if isinstance(expires, datetime) and expires < datetime.now(expires.tzinfo or timezone.utc):
        continue
    if not device_ok(plist):
        continue
    entitlements = plist.get("Entitlements") or {}
    app_id = entitlements.get("application-identifier", "")
    prefix = team + "."
    if not app_id.startswith(prefix):
        continue
    pattern = app_id[len(prefix):]
    if pattern == bundle:
        chosen = bundle
        score = 3
    elif pattern == preferred:
        chosen = preferred
        score = 2
    elif pattern == "*":
        chosen = bundle
        score = 1
    else:
        continue
    if best is None or score > best[0]:
        best = (score, path, expires, chosen)

if best is None:
    sys.exit(
        f"没有包含这台手机的描述文件。请先双击“安装到 iPhone.command”，"
        f"用你的 Apple ID 生成 {preferred} 的描述文件，然后再安装这个 IPA。"
    )

identity = None
listed = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
for line in listed.splitlines():
    if "Apple Development" not in line or '"' not in line:
        continue
    name = line.split('"', 2)[1]
    pem = subprocess.run(["security", "find-certificate", "-c", name, "-p"], capture_output=True, text=True)
    subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"], input=pem.stdout, capture_output=True, text=True).stdout
    if f"OU={team}" in subject:
        identity = line.split(")", 1)[1].split()[0]
        break
if not identity:
    sys.exit(f"钥匙串里没有团队 {team} 的 Apple Development 证书。")

_, profile, expires, bundle = best
print(f"{identity}\t{profile}\t{bundle}\t{expires}")
PY
)
identity=${plan%%$'\t'*}
rest=${plan#*$'\t'}
profile=${rest%%$'\t'*}
rest=${rest#*$'\t'}
bundle=${rest%%$'\t'*}
expires=${rest#*$'\t'}

current_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [[ $bundle != "$current_bundle" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$app/Info.plist"
    echo "Bundle ID 改为 ${bundle}"
fi

cp "$profile" "$app/embedded.mobileprovision"
entitlements="$work/entitlements.plist"
security cms -D -i "$profile" -o "$work/profile.plist" >/dev/null
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$work/profile.plist" > "$entitlements"

# 先签内层，再签 App 本体。描述文件允许的权限写在最外层。
echo "正在签名…"
while IFS= read -r item; do
    codesign --force --sign "$identity" "$item"
done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print)
codesign --force --sign "$identity" --entitlements "$entitlements" "$app"

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
echo "安装完成。这份签名在 ${expires} 失效，到期后对同一个 IPA 再运行一次。"
if ! xcrun devicectl device process launch --device "$udid" "$bundle" >/dev/null; then
    echo "已经装到手机上。若没有自动打开，请在主屏幕点一下，并在“VPN 与设备管理”里信任开发者。"
fi
