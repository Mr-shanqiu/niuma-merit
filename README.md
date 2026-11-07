# 牛马电子功德

一个离线运行的桌面小伙伴。打字或点击鼠标，它会动一下并累计功德。客户端只计数，不记录输入内容。

**当前正式版 0.9.5** · [Windows / macOS 官网下载](https://gongde.zqscreen.cn/download.html)

官网提供已签名的 Windows x64 安装包，以及已签名并经 Apple 公证的 macOS 通用安装包（构建号 905.1）。使用时直接从官网下载即可。

## 权限与数据流（可自行验证）

客户端要统计全局键鼠操作，所以 macOS 需要授予「输入监控」权限。这里说明它到底读取了什么，以及你怎么验证。

| 项目 | 内容 |
| --- | --- |
| 申请的权限 | macOS：输入监控（Input Monitoring），用于全局计数；Windows：系统低级键鼠钩子，不需要额外授权 |
| 读取的数据 | 只有事件「发生了」这一事实：按键按下或抬起、鼠标按键按下、滚轮滚动 |
| 不读取的数据 | 具体按键内容、鼠标坐标、窗口名称或标题、剪贴板、屏幕内容、进程名 |
| 数据去向 | 计数只写在本机用户目录，不上传、不联网 |
| 网络请求 | 客户端自身不发起任何网络请求；只有点击「关于 / 帮助 / 形象库」时调用系统浏览器打开官网链接 |

可以这样验证：

1. **读代码。** macOS 的全局监听在 `macos/src/macos/app.mm` 的 `EventTapCallback` 中，回调把事件对象直接丢弃（`(void)event;`），只使用事件类型，并以 `kCGEventTapOptionListenOnly` 创建只读监听。Windows 的 `KeyboardHook` / `MouseHook` 只判断按下或抬起、以及是否为注入事件，不读取按键码（`vkCode`）。
2. **抓包或断网。** 用 Little Snitch、Wireshark 或系统防火墙观察是否存在外连，或直接断网运行客户端，功能不受影响。
3. **自行构建。** 按下一节从源码构建，与官网安装包的行为对照。

本仓库只包含客户端源码。官网、支付与交付服务不在本仓库内，也不参与客户端运行。

## 从源码构建

先拉取这个仓库：

```sh
git clone https://github.com/Mr-shanqiu/niuma-merit.git
cd niuma-merit
```

### macOS

需要 Xcode 命令行工具（包含 Clang 和 macOS SDK）及 Python 3.9 或更新版本。以下命令生成供本机测试的通用客户端和安装应用：

```sh
(cd macos && NIUMA_CODESIGN_IDENTITY=- ./scripts/build-macos.sh)
./macos/scripts/build-macos-installer.sh \
  "$PWD/macos/dist/牛马电子功德.app" "$PWD/macos/dist/installer"
```

### Windows

需要 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载（含 Windows SDK）与 CMake 3.21 或更新版本：

```powershell
cmake -S windows -B windows/build -G "Visual Studio 17 2022" -A x64
cmake --build windows/build --config Release --target niuma-merit
```

产物为 `windows/build/Release/niuma-merit.exe`，包含客户端和自安装入口。两端自行构建的产物使用本机开发签名或未签名，正式安装包以官网下载为准。

## Windows 安装器（可选）

正式安装包由官方签名发布；下面说明如何用仓库内的 Inno Setup 脚本自行构建一个未签名安装器，仅用于本机测试。需要 [Inno Setup 6](https://jrsoftware.org/isinfo.php)。

```powershell
# 先按上一节构建得到客户端
cmake -S windows -B windows/build -G "Visual Studio 17 2022" -A x64
cmake --build windows/build --config Release --target niuma-merit
# 安装器脚本按 ..\..\dist\ 取产物
New-Item -ItemType Directory -Force dist | Out-Null
Copy-Item windows/build/Release/niuma-merit.exe dist/niuma-merit.exe
# 用仓库版本号编译安装器（iscc 或 ISCC.exe）
iscc /DMyAppVersion=$(Get-Content windows/VERSION) windows/installer/niuma-merit.iss
```

产物为 `dist/niuma-merit-windows-<版本>-setup.exe`，未签名。安装器默认安装到当前用户目录、无需管理员权限，并提供登录后自启与文件关联选项。

## 持续集成

`.github/workflows/build.yml` 在推送和 PR 时构建 macOS 与 Windows 客户端并上传产物，同时校验 `macos/src` 与 `windows/src` 下的共享头文件（`reminder_catalog_update.h`、`reminder_policy.h`）逐字节一致，避免两端逻辑漂移。

## 许可证

项目采用 [GNU GPL v3](LICENSE)。Windows 客户端所用的 [miniz](windows/third_party/miniz/LICENSE) 按其 MIT 许可证分发。
