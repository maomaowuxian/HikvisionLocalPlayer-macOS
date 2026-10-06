# 海康威视本地播放器 · macOS

这是 Windows 版“海康威视播放器”的 macOS Intel 移植版。当前版本使用真正的 macOS 原生外壳：

\`AppKit / WKWebView → 本机 .NET 后端 → go2rtc → 海康 ISAPI / RTSP\`

不再依赖 Google Chrome 或 Microsoft Edge 作为播放器窗口。

## 免责声明

本项目是社区维护的非官方工具，与杭州海康威视数字技术股份有限公司（Hikvision）不存在隶属、授权、赞助或官方合作关系。“Hikvision / 海康威视”及相关商标归其各自权利人所有。

本项目仅用于连接用户有权访问的设备。使用者应自行确保符合设备许可、网络安全要求及所在地法律法规。

## 当前平台

- macOS Intel x86-64
- 原生 AppKit + WKWebView 窗口
- .NET 10 LTS 自包含后台服务
- go2rtc 1.9.14 macOS amd64
- macOS Keychain 保存录像机密码

## 构建

开发机需要：

- Xcode Command Line Tools / Swift
- .NET 10 SDK（当前机器使用 \`~/.dotnet/dotnet\`）

执行：

\`\`\`bash
chmod +x src/HikvisionLocalPlayer/build-macos.sh
src/HikvisionLocalPlayer/build-macos.sh
\`\`\`

产物：

\`outputs/海康威视播放器.app\`

## App 结构

- \`Contents/MacOS/HikvisionLocalPlayerApp\`：原生 AppKit/WKWebView 主程序
- \`Contents/Resources/backend/HikvisionLocalPlayer\`：自包含 .NET 后端
- \`Contents/Resources/AppIcon.icns\`：带透明通道的原生 App 图标

主程序启动后会拉起后台服务，等待 \`127.0.0.1:1985/api/health\` 正常，再让 WKWebView 加载播放器页面。

退出 App 时会调用本机 \`/api/shutdown\`，使 .NET 后端正常释放 go2rtc 和监听端口，然后完整退出。

## 本机数据

- \`~/Library/Application Support/HikvisionLocalPlayer/Runtime\`：go2rtc 与配置
- \`~/Library/Application Support/HikvisionLocalPlayer/settings.dat\`：非敏感设置
- 录像机密码：macOS Keychain，Service 为 \`io.github.maomaowuxian.hikvisionlocalplayer\`

密码不会明文写入 settings.dat。

## 功能

- 单画面 / 四画面
- 主码流 / 子码流
- ISAPI 自动发现真实通道 ID
- PSIA RTSP 地址
- 子码流失败后自动尝试主码流
- 四路独立连接
- go2rtc 本地回环监听
- 原生 Dock / Cmd-Tab 应用归属
- 原生窗口关闭与后台生命周期联动

## 许可证

本项目以 [MIT License](LICENSE) 开源。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
