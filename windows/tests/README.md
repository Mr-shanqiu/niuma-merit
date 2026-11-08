# Windows 纯逻辑单测（S2 第一批）

覆盖 0.9.6 Windows 客户端的纯算法层，不依赖 Win32、GDI+ 或 D3D：

| 测试 | 头文件 | 覆盖 |
| --- | --- | --- |
| `work_encourager_test.cpp` | `src/client/core/work_encourager.h` | F2 时段/按秒累计/边界/货币映射/金额格式化 |
| `merit_curve_test.cpp` | `src/client/core/merit_curve.h` | F4 96 桶边界/覆盖位图/日期算术/60 天滚删/周月键 |
| `medals_test.cpp` | `src/client/core/medals.h` | F3 阈值/跨周期去重/永久点亮/集齐成就/历史补授 |
| `scroll_tick_counter_test.cpp` | `src/client/core/scroll_tick_counter.h` | F0 120 delta=1 刻度/余量/单事件与单手势上限/手势边界 |

## 运行

```sh
windows/tests/run_tests.sh
```

脚本默认用 `clang++`，按 C++17、`-Wall -Wextra -Werror` 编译四个独立可执行文件并逐个运行。
可选环境变量：

- `CXX=...`：换编译器（例如 `g++`）。
- `NIUMA_TEST_SANITIZE=1`：追加 `-fsanitize=address,undefined`。
- `NIUMA_TEST_SYSROOT=...`：macOS 上指定 SDK；脚本默认会自动挑选本机可链接的
  `MacOSX*.sdk`（部分机器 `xcrun` 选中的新 SDK 会与系统 `ld` 不兼容）。

## 与 macOS 的关系

- `work_encourager.h` / `merit_curve.h` / `medals.h` 与 `macos/src/` 下同名头文件
  的算法、常量、函数签名一致；仅注释和 `EarnedMinor` 的 64 位乘除实现不同
  （避免 MSVC 不支持 `unsigned __int128`，结果逐位相同）。
- `scroll_tick_counter.h` 是 Windows 专属：把 macOS 的像素距离换成
  `WHEEL_DELTA=120` 的整数增量，手势边界由平台调用方传入。
- 对拍记录：`macos/tests/{work_encourager,merit_curve,medals}_test.cpp` 不改一行，
  用 `-I windows/src/client/core` 编译到 Windows 头也全部 PASS；本目录的测试是
  在此基础上扩充边界用例。
- 本目录不参与 `windows/CMakeLists.txt` 的正式构建；后续可加 `NIUMA_BUILD_TESTS`
  选项接入 CTest/CI（见 `windows/PHASE2_PLAN.md`）。
