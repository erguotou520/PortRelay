# PortRelay

PortRelay 是一个原生 SwiftUI macOS 端口映射应用，同时提供 SSH 和 Kubernetes 端口转发的图形化管理界面。

应用图标以服务器节点、转发隧道和在线状态为核心视觉，并已随独立应用包安装。

## 功能

- 左侧管理服务器，支持新增、右键修改和删除。
- 从 `~/.ssh/config` 选择单台服务器，或在默认全选的弹窗中批量导入具体 `Host`（包含 `Include` 文件）。
- 手动配置 IP/域名、SSH 端口、用户名，以及密码、私钥路径、粘贴私钥或系统 SSH Agent。
- 服务器与端口映射都支持 Command/Shift 多选删除，端口列表同时支持搜索、增删改查、启动和停止。
- 映射状态实时显示为未启动、连接中、已映射或失败，并保留 SSH 错误信息。
- 记住映射的启用状态；正常退出会停止 SSH 子进程，重新打开应用后自动恢复此前启用的映射。
- 密码保存在 macOS 钥匙串；粘贴的私钥保存在应用支持目录并设置为 `0600` 权限。
- 顶部可切换到 Kubernetes 模式，以“集群 → Namespace → 端口”三栏浏览 Service、Deployment 和 Pod。
- Kubernetes 集群支持选择本地 kubeconfig，或直接粘贴 YAML；同一份配置中的 Context 可分别添加。
- 可将 Service/Deployment 声明的 TCP 端口映射到 `127.0.0.1` 或 `0.0.0.0`，并支持修改、删除、启动、停止和失败重试。
- Kubernetes 映射会记住启用状态，应用重新打开后通过 `kubectl port-forward` 自动恢复。
- Deployment 支持选择运行中的 Pod，流式查看并搜索日志，或自动使用 bash、降级到 sh 建立 Shell 会话。
- Pod 支持直接配置端口映射、流式查看日志和打开交互式 Shell。
- 未声明 `containerPort` 的 Deployment 和 Pod 仍会显示，可查看日志、打开 Shell，并手动填写远程端口进行映射。
- SSH 服务器支持直接打开交互式 Shell；Kubernetes 日志、Kubernetes Shell 和 SSH Shell 统一显示在全局底部面板，切换工作区时会话仍会保留。

## 开发与构建

在 Xcode 中打开 `Package.swift` 即可运行。生成独立应用：

```sh
./Scripts/build-app.sh
```

产物位于 `dist/PortRelay.app`，最低支持 macOS 14。

生成可分发的 ZIP 和 DMG：

```sh
./Scripts/build-dmg.sh
```

产物位于 `dist/PortRelay-macOS.zip` 和 `dist/PortRelay.dmg`。

## CI

GitHub Actions 会在推送到 `main`、提交 Pull Request 或手动触发时运行测试并打包。构建完成后，可在对应工作流页面的 Artifacts 区域下载 `PortRelay-macOS`，其中包含 ZIP 和 DMG。CI 产物使用临时签名，适合测试和内部安装；公开分发仍需配置 Apple Developer ID 签名与公证。

## 使用说明

1. 添加或导入服务器。
2. 选中服务器，在右侧添加端口映射。
3. 右键映射选择“启动映射”，或点击行尾播放按钮。
4. 退出应用时，应用创建的所有 SSH 映射进程都会停止。

Kubernetes 映射需要本机已安装 `kubectl`，并且 kubeconfig 对目标 Namespace、Service、Deployment 和 Pod 具有相应读取/转发权限。退出应用时，应用创建的 `kubectl port-forward` 进程也会停止。

监听 `0.0.0.0` 会让同一网络中的其他设备也可能访问该端口，请结合 macOS 防火墙谨慎使用。
