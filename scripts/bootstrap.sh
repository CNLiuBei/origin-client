#!/bin/zsh
# 拉取本地依赖（KSPlayer 2.3.4 源码版 + FFmpegKit 6.1.4），并生成 Xcode 工程。
# 如需代理：export https_proxy=http://127.0.0.1:7897
set -e
cd "$(dirname "$0")/.."
mkdir -p Vendor
[ -d Vendor/KSPlayer ] || git clone --depth 1 --branch 2.3.4 https://github.com/kingslay/KSPlayer.git Vendor/KSPlayer
[ -d Vendor/FFmpegKit ] || git clone --depth 1 --branch 6.1.4 https://github.com/kingslay/FFmpegKit.git Vendor/FFmpegKit
scripts/fix-ffmpegkit-macos.sh
[ -f Config/Secrets.xcconfig ] || cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
xcodegen generate
