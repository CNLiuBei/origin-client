# Origin

在 iPhone、iPad 和 Mac 上连接自己的媒体服务器，浏览片库并播放。支持 Jellyfin、Emby、Plex 和飞牛影视。

观看进度、已看和收藏由媒体服务器保存。Origin 自己保管的是服务器列表、登录状态和播放设置。

## 功能

- 局域网里可以发现飞牛影视和 Plex。Jellyfin 与 Emby 需要手动填写地址。
- 首页可以聚合多台服务器，也可以把某一台排除在外。
- 播放内核可以自动选择：系统能播的交给系统播放器，MKV、DTS、ASS 等交给 FFmpeg。也可以固定用其中一种。
- 可以记住播放位置、自动播下一集，并设置倍速、快进快退、音轨和字幕。FFmpeg 内核可以调整字幕字号、颜色、底边距和半透明背景。
- 影片信息可以用 TMDB 补充 Logo、预告片、标语和演员头像。
- 影片可以下载到本机离线看。下载的文件不参与同步。
- 服务器可以添加备用线路。也可以给服务器加上本机认证，打开前用 Face ID 或密码确认。
- 打开 iCloud 同步后，同一 Apple 账号下的设备会同步服务器、登录令牌和播放设置。各设备仍各自选择当前服务器。

iCloud 同步需要开发者账号开通 Key-value storage，并重新签名。个人免费团队的描述文件不包含这项能力，设置里的开关会保持不可用。

## 环境

- Xcode，以及 iOS 26、macOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 网络。首次执行会克隆 KSPlayer 2.3.4 和 FFmpegKit 6.1.4

## 编译

```sh
scripts/bootstrap.sh
open Origin.xcodeproj
```

工程文件由 `project.yml` 生成，不放进仓库。依赖在 `Vendor/`，同样不放进仓库。

TMDB 的 Read Access Token 写在 `Config/Secrets.xcconfig`。这个文件被 git 忽略。没有它也能编译和播放，只是不会去拉 TMDB 的补充信息。示例在 `Config/Secrets.example.xcconfig`。

Xcode 里运行 Origin（iPhone / iPad）或 OriginMac。

## 许可

播放使用 [KSPlayer](https://github.com/kingslay/KSPlayer) 和 FFmpeg，二者为 GPL-3.0。本仓库源码同样按 GPL-3.0 提供。

影片资料来自 TMDB。Origin 使用 TMDB API，但没有获得 TMDB 的认可或认证。

## 支持作者

Origin 免费使用。如果它帮你看完了一部片，可以用微信扫下面的码支持作者。

![微信赞赏，账户名喜欢可爱](打赏码.JPG)
