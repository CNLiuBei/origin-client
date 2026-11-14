#!/bin/zsh
cd "$(dirname "$0")"
if [[ $# -ge 1 ]]; then
    scripts/install-ipa.sh "$1"
else
    scripts/install-ipa.sh
fi
exit_code=$?
echo
if [[ $exit_code -ne 0 ]]; then
    echo "安装没有完成，退出码 ${exit_code}。"
fi
echo "按回车关闭窗口。把 IPA 拖到这个文件上也可以安装。"
read -r
exit $exit_code
