# 第三方组件说明

本项目内置 [go2rtc](https://github.com/AlexxIT/go2rtc) 作为本机 RTSP 到 WebRTC/MSE 的媒体桥接组件。

- 组件版本：1.9.14
- 构建：官方 macOS Intel x86-64（go2rtc_mac_amd64.zip）
- 发布包 SHA-256：9b0b9a27a4dc3a5b8b93376e7e8fc2787c6af624a512842622be84aec0171c7a
- 许可证：MIT License
- 原始许可证文本：`src/HikvisionLocalPlayer/Resources/go2rtc-LICENSE`

go2rtc 仅监听本机回环地址 `127.0.0.1`。播放器退出时，由本程序启动的 go2rtc 进程会一并结束。
