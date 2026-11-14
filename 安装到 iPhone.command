#!/bin/zsh
cd "$(dirname "$0")"
scripts/install-iphone.sh
exit_code=$?
echo
if [[ $exit_code -ne 0 ]]; then
    echo "安装没有完成，退出码 ${exit_code}。"
fi
echo "按回车关闭窗口。"
read -r
exit $exit_code
