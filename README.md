# NodeStatusBar

NodeStatusBar 是一个 macOS 状态栏节点监控小工具，用于查看 HTTP/HTTPS 与 Hysteria2 节点的在线状态、断连次数和断连日志。

## 功能

- 状态栏显示手动选择的节点状态。
- 支持 HTTP/HTTPS 节点可用性检测。
- 支持 Hysteria2 节点检测，并通过本地 Hysteria HTTP 代理访问测试地址。
- 支持延迟检测开关：
  - 开启时显示真实链路延迟。
  - 关闭时只显示节点是否正常，检测频率更高。
- 支持断连次数、断连日志、断连恢复时间和提示音。
- 节点地址默认隐藏，可手动切换可见。
- App Sandbox 开启，仅申请网络 client/server 权限。

## 隐私说明

项目源码不包含任何默认节点、订阅链接、服务器地址、用户名、密码或 token。

节点配置保存在本机 `UserDefaults` 中，不会上传到 GitHub，也不会随源码发布。公开 issue、截图或日志时，请先隐藏节点地址和服务端信息。

## 系统要求

- macOS
- Xcode
- Apple Silicon Mac

当前仓库内置了 macOS arm64 版 Hysteria 客户端二进制。如果你不想使用内置二进制，也可以安装系统版 Hysteria，程序会按顺序查找：

1. App Bundle 内的 `Resources/hysteria`
2. `/opt/homebrew/bin/hysteria`
3. `/usr/local/bin/hysteria`

## 从源码构建

```bash
git clone https://github.com/252201/NodeStatusBar.git
cd NodeStatusBar

xcodebuild \
  -project NodeStatusBar.xcodeproj \
  -scheme NodeStatusBar \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

构建产物位于：

```bash
build/DerivedData/Build/Products/Release/NodeStatusBar.app
```

安装到 `/Applications`：

```bash
ditto \
  "build/DerivedData/Build/Products/Release/NodeStatusBar.app" \
  "/Applications/NodeStatusBar.app"

open "/Applications/NodeStatusBar.app"
```

## 从 Release 安装

也可以从 GitHub Releases 下载打包好的 `NodeStatusBar.app.zip`：

```text
https://github.com/252201/NodeStatusBar/releases
```

下载后解压，把 `NodeStatusBar.app` 拖到 `/Applications` 并打开。未公证的开源构建首次运行时，macOS 可能会提示身份无法验证；如果介意这一点，建议按上面的“从源码构建”方式自行构建。

## 使用方法

1. 启动 `NodeStatusBar.app`。
2. 点击状态栏图标，选择“设置节点...”。
3. 添加节点名称和节点地址。
   - HTTP/HTTPS 示例：`https://example.com/health`
   - Hysteria2 示例：`hysteria2://...`
4. 点击节点行左侧图钉，选择状态栏要显示的节点。
5. 在菜单里打开或关闭“延迟检测”。
6. 节点断连时，断连日志会记录开始时间、恢复时间、持续时长和原因。

## 说明

Hysteria2 节点检测会为每个节点维护一个常驻本地 Hysteria HTTP 代理，再通过该代理访问测试地址来判断节点状态。退出 App 时会停止相关 Hysteria 进程。

## 第三方组件

本项目可随 App 打包 Hysteria 客户端二进制。Hysteria 项目使用 MIT License，详见：

- https://github.com/apernet/hysteria
- https://v2.hysteria.network/

## License

MIT
