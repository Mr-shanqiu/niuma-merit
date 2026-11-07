# 牛马电子功德

一个离线运行的桌面小伙伴。打字或点击鼠标，它会动一下并累计功德。客户端只计数，不记录输入内容。

**当前正式版 0.9.5** · [Windows / macOS 官网下载](https://gongde.zqscreen.cn/download.html)

官网提供已签名的 Windows x64 安装包，以及已签名并经 Apple 公证的 macOS 通用安装包（构建号 905.1）。使用时直接从官网下载即可。

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

## 许可证

项目采用 [GNU GPL v3](LICENSE)。Windows 客户端所用的 [miniz](windows/third_party/miniz/LICENSE) 按其 MIT 许可证分发。
