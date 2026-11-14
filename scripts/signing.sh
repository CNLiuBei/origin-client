#!/bin/zsh
# 由安装脚本 source。选出本机钥匙串里的 Apple Development 团队。
# 只有工程里写死的团队继续用 com.cn.Origin；其他人自动换成 com.cn.Origin.<团队号>，避免 Bundle ID 被占用。
# 想固定下来：复制 Config/Signing.local.example 为 Config/Signing.local。

sign_resolve() {
    local project_team project_bundle
    project_team=$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)
    project_bundle=$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ && $2 !~ /UITests/ {print $2; exit}' project.yml)
    SIGN_TEAM=""
    SIGN_BUNDLE=""

    if [[ -f Config/Signing.local ]]; then
        # 本地文件可设置 DEVELOPMENT_TEAM、PRODUCT_BUNDLE_IDENTIFIER
        source Config/Signing.local
    fi

    if [[ -n ${DEVELOPMENT_TEAM:-} ]]; then
        SIGN_TEAM=$DEVELOPMENT_TEAM
    else
        local listed choice
        listed=$(python3 - <<'PY'
import re, subprocess, sys
raw = subprocess.check_output(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"], text=True, errors="replace")
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", raw, re.S)
seen = []
for pem in certs:
    result = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"], input=pem, text=True, capture_output=True)
    subject = result.stdout.strip()
    team = re.search(r"(?:^|,)OU=([^,]+)", subject)
    name = re.search(r"(?:^|,)CN=([^,]+)", subject)
    if not team:
        continue
    item = (team.group(1), name.group(1) if name else team.group(1))
    if item not in seen:
        seen.append(item)
if not seen:
    sys.exit(0)
for team, name in seen:
    print(f"{team}\t{name}")
PY
)
        if [[ -z $listed ]]; then
            echo "这台 Mac 还没有你的开发证书。" >&2
            echo "打开 Xcode → Settings → Accounts，用你自己的 Apple ID 登录，然后重新双击安装。" >&2
            return 1
        fi
        local teams=("${(@f)listed}")
        if [[ ${#teams} -eq 1 ]]; then
            SIGN_TEAM=${teams[1]%%$'\t'*}
        elif [[ -t 0 ]]; then
            echo "这台 Mac 有多个开发团队，输入序号选用你自己的：" >&2
            local index=1
            for line in "${teams[@]}"; do
                echo "  ${index}) ${line#*$'\t'}  ${line%%$'\t'*}" >&2
                index=$((index + 1))
            done
            read -r "choice?序号："
            if [[ ! $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#teams} )); then
                echo "没有这个序号。" >&2
                return 1
            fi
            SIGN_TEAM=${teams[$choice]%%$'\t'*}
        else
            echo "这台 Mac 有多个开发团队。请在 Config/Signing.local 里写 DEVELOPMENT_TEAM=你的团队号" >&2
            printf '%s\n' "$listed" >&2
            return 1
        fi
    fi

    if [[ -n ${PRODUCT_BUNDLE_IDENTIFIER:-} ]]; then
        SIGN_BUNDLE=$PRODUCT_BUNDLE_IDENTIFIER
    elif [[ $SIGN_TEAM == $project_team ]]; then
        SIGN_BUNDLE=$project_bundle
    else
        SIGN_BUNDLE="com.cn.Origin.${(L)SIGN_TEAM}"
    fi

    echo "签名：${SIGN_TEAM} · ${SIGN_BUNDLE}"
}
