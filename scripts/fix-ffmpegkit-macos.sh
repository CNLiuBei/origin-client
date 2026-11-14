#!/bin/zsh
# FFmpegKit 的 macOS 切片是浅层 framework（iOS 结构），macOS 打包时会因
# “expected Versions/Current/Resources/Info.plist” 校验失败。
# 这里把每个 xcframework 的 macos-* 切片改成标准的 Versions/A 深层结构，可重复执行。
set -e
cd "$(dirname "$0")/../Vendor/FFmpegKit/Sources"
for framework in *.xcframework/macos-*/*.framework(N); do
    if [ -d "$framework/Versions" ]; then continue; fi
    name=${${framework:t}%.framework}
    (
        cd "$framework"
        mkdir -p Versions/A/Resources
        mv Info.plist Versions/A/Resources/
        mv "$name" Versions/A/
        for dir in Headers Modules PrivateHeaders; do
            if [ -d "$dir" ]; then mv "$dir" Versions/A/; fi
        done
        ln -s A Versions/Current
        ln -s "Versions/Current/$name" "$name"
        ln -s Versions/Current/Resources Resources
        for dir in Headers Modules PrivateHeaders; do
            if [ -d "Versions/A/$dir" ]; then ln -s "Versions/Current/$dir" "$dir"; fi
        done
    )
    echo "已转换 $framework"
done
