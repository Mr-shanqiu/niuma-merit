# PHASE 2 PLAN · Windows 平台胶水（0.9.6 / F0–F4 + F1 + L1–L4）

- 状态：S2 第一批（纯逻辑移植）已完成，本文件是第二批（平台胶水）的施工单。
- 基线：`codex/096-windows` @ `dc6e7b3`（= `codex/096-macos`）。
- 范围：只改 `windows/**`；不改 `macos/**`、`reminder_*.h`、`reminder_catalog_data.h`。
- 依据：`docs/CONTRACT_096.md` §1–§9、`docs/FEATURE_FREEZE.zh-CN.md` v3、
  `docs/REQUIREMENTS_INTERNAL.zh-CN.md` F0–F4/L1–L4，以及 macOS S1 实现
  （`app.mm`、`input_runtime.mm`、`work_encourager.h`、`merit_curve.h`、`medals.h`）。
- 本机限制：macOS 无 MSVC；纯逻辑可用 `clang++` 验证，平台胶水必须在 Windows
  VM/CI 上编译与实机验收后才能合并。

---

## 0. 本批已交付（第二批的前置）

| 文件 | 作用 | 单测 |
| --- | --- | --- |
| `windows/src/client/core/work_encourager.h` | F2 时段、按秒累计、货币映射、金额格式化 | `work_encourager_test.cpp` |
| `windows/src/client/core/merit_curve.h` | F4 96 桶、覆盖位图、日期算术、60 天滚删、周/月键 | `merit_curve_test.cpp` |
| `windows/src/client/core/medals.h` | F3 阈值、周期键、去重计次、历史补授、集齐成就 | `medals_test.cpp` |
| `windows/src/client/core/scroll_tick_counter.h` | F0 120 delta=1 刻度、余量、单事件/单手势上限、手势边界入参 | `scroll_tick_counter_test.cpp` |
| `windows/tests/run_tests.sh` | 用 `clang++ -std=c++17 -Wall -Wextra -Werror` 编译并运行四个测试 | — |

本批不接入 `windows/CMakeLists.txt` 的正式构建（顶层 CMake 只允许 MSVC/Windows），
因此测试是独立可执行文件；第二批可在 CMake 里加 `NIUMA_BUILD_TESTS` 选项接入 CTest。

---

## 1. 施工原则

1. **先落盘、后采集、再 UI**：侧车存储是 F2/F3/F4 的共同地基，先做；否则后面
   每加一个功能都要改一次持久化。
2. **旧 `data.ini` 只读兼容**：0.9.6 新数据一律进
   `%LOCALAPPDATA%\NiuMaMerit\metrics-096.json`（CONTRACT §1.2/§4.2），
   绝不把新键并入 `data.ini`。`[daily]` 仍是日总数/勋章归集的唯一权威。
3. **输入线程不碰磁盘/渲染**：现有 `InputService` 的“输入线程只做内存记账”边界
   必须保持；曲线桶与勋章求值都在 UI/存储侧消费快照后完成。
4. **与 macOS 常量单点对齐**：滚动上限、空闲手势间隔、勋章阈值、桶数/保留天数
   只放在本批四个头（或共享常量）里；平台胶水不复制魔数。
5. **不引入新运行时依赖**：D3D11/GDI+/WIC/Comctl32 已在链接列表；不新增 DLL。
6. **每一步都可回退**：侧车原子写 + 坏块降级；旧数据不被改写；0.9.5 可回退。

---

## 2. 推荐顺序与依赖

```text
P2-A 地基
  A1 metrics-096 侧车存储（metrics_store）
  A2 F0 滚动距离计数（input_service + InputCore + app.cpp 回退路径）
  A3 F4 桶采集（InputCore 预分配曲线槽 + 心跳命令 + ledger 扩展）

P2-B 功能（A 完成后可并行）
  B1 F4 曲线窗口/持久化/60 天滚删
  B2 F2 上班鼓励器（场景/设置/底栏/侧车）
  B3 F3 勋章（求值/墙/历史补授/侧车）
  B4 F1 形象大小（缩放/钳位/持久化/命中区）

P2-C 产出与本地化
  C1 F3/F4 分享图（share_card，白名单模型）
  C2 L1–L4 四语 UI + 安装器
  C3 组合渲染/文本缓存容量与验收打磨

P2-D 验收
  D1 Windows CI（MSVC 构建 + 纯逻辑测试 + 侧车恢复测试）
  D2 Windows 实机 4 场景 F0、F2 按秒、F3 跨周月、F4 桶/60 天、F1 极限档
```

依赖关系：

- `A1` 是 `B1/B2/B3` 的前置；`A2` 是 `A3` 的前置（曲线按“实际计数增量”记账）。
- `B3` 只依赖旧 `[daily]`，不依赖 `B1` 的曲线数据；但两者共用侧车，所以排在 `A1` 后。
- `C1` 依赖 `B1`（曲线数据）与 `B3`（勋章记录）。
- `B4` 与 `B1/B2/B3` 无强依赖，可并行；但会改主窗口几何，建议在 `B2` 底栏布局
  确定后做，避免两次改 `MainWindowDipHeight()`。

---

## 3. 逐功能施工单

### 3.1 A1 · `metrics-096.json` 侧车（F2/F3/F4/F1 共同地基）

**新增文件**

- `windows/src/windows/runtime/metrics_store.h/.cpp`
  - 路径：`DataPath()` 同目录下 `metrics-096.json`；隔离验收模式跟随
    `gAcceptanceRoot`（`app.cpp:794 DataPath()`）。
  - 顶层结构严格按 CONTRACT §4.2：
    `schema_version=1`、`namespace="niuma.gongde.v096"`、`app_version`、
    `updated_at_utc`、`migration`、`prefs`、`encourager`、`medals`、`curve`。
  - 原子写：`metrics-096.json.tmp` → flush/fsync → `ReplaceFile`/`MoveFileEx`
    原子替换；写前把正式文件复制为 `metrics-096.previous.json`；启动时正式文件
    解析失败 → 尝试 previous → 仍失败则改名 `metrics-096.corrupt-<epoch>.json`
    并重建空侧车；清理残留 `.tmp`。
  - 1 MiB 硬上限；超限先修剪最旧 `curve.days`（只删桶），仍超限则拒绝本次写入
    并保留旧文件（不能写坏）。
  - 块级降级：`curve`/`medals`/`encourager`/`prefs` 任一坏块只回默认值，
    其余块照常；解析错误写 `metrics-096.errors.log`（不含路径/个人信息）。
  - 未知字段保留：读取时保留原始 `JsonValue` 树中本版本不认识的键，写回时合并，
    满足 CONTRACT §1.1“读端忽略未知字段、写端保留未知字段”。
  - 写入由独立 worker 完成（仿 `StorageService` 的 immutable write/result 模式），
    绝不在输入回调或渲染路径做文件 I/O；同一时刻最多一个 in-flight。
- `windows/src/windows/runtime/metrics_json.h/.cpp`（或 `metrics_store.cpp` 内部）
  - CONTRACT 的 `curve.buckets` 允许十进制字符串表示 >2^53 的 uint64；
    `appearance_scale` 允许字符串小数。**不要直接复用
    `reminder_catalog_update.h` 的 `JsonParser`**：它只接受 int64 整数、拒绝
    `1.0` 这类小数，会把合法侧车判坏。需要一个小型 JSON 读写器：
    - 读：整数、字符串小数、字符串 uint64（`strtoull` + 全串校验）；
    - 写：≤2^53 写 JSON 数字，>2^53 写十进制字符串；
    - 深度/节点/大小上限，拒绝重复键/尾随内容。
- `windows/tests/metrics_store_test.cpp`（新增，纯逻辑）
  - 往返、坏块降级、previous 恢复、corrupt 改名、1 MiB 修剪、>2^53 字符串、
    `appearance_scale` 字符串小数、未知字段保留。

**改动文件**

- `windows/CMakeLists.txt`：新增 `niuma-windows-metrics`（或并入
  `niuma-windows-storage`），链接 `niuma-runtime-core`/`Threads`；不新增外部库。
- `windows/src/windows/app.cpp`
  - 启动：`InitializeDataStorage()`（L860）之后、`LoadOffworkSettings()` 之前
    初始化 `MetricsStore`；失败只降级新功能，不阻止启动（CONTRACT §5.3）。
  - 退出：`BeginClientClose`/`ContinueClientClose`（L~5060）在数据落盘后
     flush 侧车；`Stop` 超时处理与 `StorageService` 一致。
  - `SaveState()`/`PumpDataStorage()` 旁边增加 `PumpMetricsStore()`。

**验收**

- 侧车不存在 → 以默认值创建，`migration.from_095=true`、`legacy_source="data_ini"`；
  旧 `[daily]` 不复制成曲线桶。
- 人为截断/写坏侧车 → 启动不失败，坏块回默认，旧 `data.ini` 不变。
- 写入过程中杀进程 → 重启读到旧版或新版完整文件，无半写。
- 60 天上界 + 每桶 20 位数字 → 文件 < 1 MiB。

---

### 3.2 A2 · F0 滚动距离计数

**现状**

- 新输入路径：`windows/src/windows/runtime/input_service.cpp`
  - `Mouse()` L192–221 只把 `WM_MOUSEWHEEL/WM_MOUSEHWHEEL` 变成
    `InputKind::Scroll`，**丢掉了 `MSLLHOOKSTRUCT.mouseData` 里的 delta**。
  - `Observe()` L130–155 用 `core.StartsScrollGesture(now)` 判断“是否新手势”，
    再交给 `InputCore::Observe`；后者在 `input_state.cpp:207-213` 每手势只计 1 次。
- 回退路径：`app.cpp`
  - `kScrollGestureGapMs=180` L141；`CountScrollGesture()` L2353 每 180ms 只计 1 次；
    `MouseHook` L2731 只 `QueueGlobalInput(kScrollMessage,3)`，同样丢 delta；
    `CountGlobalDelivery()` L2762 调 `CountScrollGesture()`。
- 自检文案：`app.cpp` L3066–3067、L3100（“连续滚动按一次手势计数”）。

**改动**

1. `windows/src/client/core/input_state.h/.cpp`
   - `InputEvent` 增加：
     - `int scroll_ticks = 0;`（本事件应增加的功德数，0..4）
     - `int minute_of_day = -1;`（F4 用；见 A3）
   - `InputCore::Observe` 的 `Scroll` 分支：`scroll_ticks <= 0` → `Ignored`；
     `>0` → 连续调用 `Count()`（或新增 `CountOperations(n)`，一次更新
     total/today/actionSerial/strike，避免 N 次动画抖动）。
   - 删除/替换 `StartsScrollGesture()` 与 `kScrollGestureGapMs=180`：
     手势边界移到 `input_service`（调用方），`InputCore` 不再做时间去抖。
   - 保留 `InputKind::Scroll` 的 reminder `ScrollPulse` 观察（每个物理事件一次，
     与计数刻度无关）。
2. `windows/src/windows/runtime/input_service.cpp/.h`
   - `Impl` 增加 `client::core::ScrollTickCounter scrollCounter;`
     `std::uint64_t lastScrollMs = 0; bool hasScroll = false;`
   - `Mouse()`：
     - 从 `MSLLHOOKSTRUCT::mouseData` 高 16 位取带符号 wheel delta
       （`static_cast<short>(HIWORD(mouseData))`；`WM_MOUSEHWHEEL` 同样）；
     - `newGesture = !hasScroll || ScrollTickCounter::IdleGapExceeded(lastScrollMs, now)`
       （350ms，与 macOS `kIdleGestureGap` 对齐）；
     - `ticks = scrollCounter.Consume(delta, newGesture)`；
     - 把 `ticks` 放进 `InputEvent` 后调用 `Observe`；`hasScroll=true; lastScrollMs=now`。
   - `Observe()` 自检：
     - `expected` 不再用 `core.StartsScrollGesture`，改为“本事件 ticks”；
     - `check.scrolls` 仍按物理滚动事件 +1；
     - `check.expected += ticks`；`check.counted += ticks`（仅当 `Counted`）。
   - 监听器重启（`Install()`/`RestartListeners`）时 `scrollCounter.BeginGesture()`，
     避免旧手势余量跨代。
   - `InputServiceSnapshot`/`InputServiceStop` 不需要新增字段（ticks 已计入总数）。
3. `windows/src/windows/app.cpp`（回退路径，`gInput.authoritative == false` 时使用）
   - `kScrollGestureGapMs` 改为引用 `ScrollTickCounter::kIdleGestureGapMs`（350），
     或删除常量。
   - 增加 `ScrollTickCounter gFallbackScrollCounter;` 与
     `ULONGLONG gFallbackLastScrollMs`。
   - `MouseHook`：取 delta，计算 `newGesture`，`Consume` 得到 ticks；把 ticks
     随 `kScrollMessage` 投递（`wParam`/`lParam` 都是 64 位，足够放
     listenerGeneration + delta/ticks；不要用会被后续事件覆盖的全局变量）。
   - `CountGlobalDelivery()` → `CountScrollTicks(int ticks)`：
     循环 `CountOneOperation()`；`gCountingCheck.expected/counted` 按 ticks 累加。
   - 更新自检文案：
     - L3066–3067 的“只观察到同一段连续滚动……”改为“滚动距离不足 1 刻度，
       未产生计数；继续滚动或稍后再试，不判失败。”
     - L3100 的“连续滚动按一次手势计数”改为“滚动按距离累计，每 120 增量计 1 次；
       单次手势最多 30 次。”
     - L3268 的隐私说明“scroll gestures”可改为“scroll distance”以与新口径一致。
4. `windows/tests/input_state_test.cpp`（新增，纯逻辑）
   - 构造 `InputCore`，喂 `InputEvent{Scroll, scroll_ticks=N}`：
     - N=0 → Ignored，total 不变；
     - N=1/4 → total/today 增加 N；
     - 非 Scroll 事件不受影响；
     - `scroll_ticks` 与 `InputKind::KeyUp`/Click 的组合。
   - 若保留 `InputCore::StartsScrollGesture` 的兼容接口，测试其新语义；否则删除。

**验收（实机 4 场景）**

- 慢滚 1 格 = 1 次；快滚连续多格 = 多计；触控板小增量累计到 120 才计 1；
  触控板轻点（delta 很小）= 0 或 1（按累计），不再“每手势只 1 次”。
- 一次甩动最多 30 次；单条异常事件最多 4 次。
- 自检“应增加/实际增加”一致；文案不再声称按手势。

---

### 3.3 A3 · F4 桶采集（输入侧）

**设计选择**

`InputCore` 已经拥有“输入线程独占、回调不分配”的日账本。曲线桶也应放在同一
owner，但**不要**给 4096 个历史日都配 96 桶（4096 × 780B ≈ 3.2MB，且 ledger
复制过重）。建议：

- `InputCore` 增加一个固定容量的近期曲线环：`kCurveDayCapacity = 64`
  （60 天保留 + 4 天余量）。
- 记录结构：`struct CurveDayRecord { LocalDate date; curve::CurveDay day; };`
- `InputEvent` 增加 `int minute_of_day`（-1 表示不适用）；`Count()` 里
  `curve::BucketForMinute(minute_of_day)` → `day.AddCount(bucket,1)`。
- 日期切换时把最旧日期移出环；`CopyCurveDays(CurveDayRecord* out, capacity)`
  只复制有覆盖或非零的近期记录。
- 心跳：`InputCommandKind::MarkCurveObserved`，命令携带 `capturedDate` +
  `minute_of_day`；输入线程执行 `MarkObserved(bucket)`（真零覆盖）。
  `app.cpp` 的 `kReminderTimer`（1s）或 `kDayTimer`（30s）里每 60s 发一次，
  保证“运行过但没计数”的桶 coverage=1。
- 曲线桶只从**实际计数增量**记账：`CountOperations(n)` 里循环 `AddCount`，
  与 `[daily]` 同批更新，满足 CONTRACT §4.3 `dailyTotal == sum(covered buckets)`
  （升级当天部分采集除外）。

**改动**

- `windows/src/client/core/input_state.h/.cpp`：上述环、`CopyCurveDays`、
  `MarkCurveObserved`（owner-only）。
- `windows/src/client/core/ledger_snapshot.h`：
  - `LedgerSnapshotResult` 增加 `std::vector<CurveDayRecord> curve;`
  - `LedgerSnapshotChannel` 预分配第二个 `curveBuffer_`（容量 64），
    `ProduceIfRequested` 复制、`TryConsume` 赋值；保持“只分配一次”的约束。
- `windows/src/windows/runtime/input_service.cpp`：
  - 每个输入事件捕获 `minute_of_day`（`GetLocalTime` 的
    `wHour*60+wMinute`；跨天由 `CaptureLocalDate` 保证同一次系统时间读取，
    避免 23:59:59 日期/分钟错位）。
  - 处理 `MarkCurveObserved` 命令。
- `windows/src/windows/runtime/input_service.h`：`InputCommand` 增加
  `minute_of_day` 字段（复用 `capturedDate`）。

**验收**

- 23:59:59 与 00:00:00 的事件分别进旧日桶 95 / 新日桶 0。
- 14:59 → 桶 59；15:00 → 桶 60；23:59 → 桶 95（与单测一致）。
- DST 跳过小时无事件 → coverage 0；重复小时两次事件 → 同桶相加、coverage 1。
- 心跳后无事件的桶 coverage=1 且 bucket=0（真零）。
- 输入线程仍无文件/UI 调用；ledger 复制只在 owner 侧。

---

### 3.4 B1 · F4 曲线窗口、持久化与 60 天滚删

**改动**

- `windows/src/windows/app.cpp`
  - 菜单：`kMenuCurve = 11`，`ShowContextMenu()` L4931 增加
    “牛马曲线…”/“Merit Curve…”（放在功德日历旁边），命令分支调
    `ShowMeritCurve(window)`。
  - 新窗口：仿 `ShowMeritCalendar()` L4085 的 GDI+ 对话框模式，新增
    `kCurveClass`、`CurveState`、`ShowMeritCurve`、`DrawMeritCurve`、
    `LayoutCurve`、日/周/月切换按钮（`kCurveDay/Week/Month`）。
    - 日视图：96 桶 x 轴（每 3 小时一个刻度），y=该桶功德；
      coverage=0 的桶画“未采集”底纹，不画 0。
    - 周视图：`curve::WeekDayKeys()` 7 天，y=旧 `[daily]` 日总数。
    - 月视图：`curve::MonthDayKeys()`，y=旧 `[daily]` 日总数。
    - 数据来源：日视图用侧车 `curve.days`；周/月用 `ReadDailyTotal()`
      （`app.cpp:909`），不伪造桶。
  - 60 天滚删：每次 flush 前用 `curve::KeysToPrune(keys, todayKey, 60)`，
    只删 `curve.days` 条目；旧 `[daily]` 不动（CONTRACT §5.2）。
  - 降级对账：启动时若 `[daily]` 有晚于 curve 最后日的日，补建
    `coverage=全0` 的 curve 条目（CONTRACT §5.5），不伪造桶。
- `windows/src/windows/runtime/metrics_store.*`：curve 块读写/修剪/上限。
- `windows/src/windows/runtime/client_display.*`：**不参与**曲线窗口（独立
  GDI+ 窗口），避免主 widget 文本缓存膨胀。
- `windows/tests/merit_curve_test.cpp` 已覆盖桶/覆盖/滚删；再加
  `metrics_store_test` 覆盖“只删桶、不删日总数”的合并逻辑。

**验收**

- 三视图正确；日视图 96 桶；周/月边界按本地自然周/月。
- 60 天窗口：第 61 天滚删；旧 `[daily]` 仍可用于日历/勋章。
- 升级当天部分采集：日总额可能大于桶和，窗口显示“部分采集”。

---

### 3.5 B2 · F2 上班鼓励器

**场景与几何**

- `app.cpp`
  - `MeritScene` L192 增加 `Encourager = 4`（与 macOS `MeritSceneEncourager`
    对齐）；`SceneTitle()` L3801 增加“上班鼓励器”/“Work Encourager”。
  - 内置形象 ID：`"builtin.encourager"`；`ShowAppearancePicker()` L4386 的
    内置卡片列表加入该项；`CurrentAppearancePack()`/`ReadSelectedPackId()`
    识别它（不当作外部包）。
  - `DrawSceneArtwork()` L1665 增加鼓励器插画（工牌/工资条，GDI+ 画，
    与 macOS `NMEncouragerArtwork` 同风格；不新增 PNG 资源也可）。
  - `MainWindowDipHeight()` L509：
    `125 + (offwork?44:0) + (encouragerActive?84:0)`；`ResizeOffworkWindow()`
    重命名为 `ResizeRegionLayout()`，按 `desiredExtraRegionHeight` 统一调整，
    保持窗口左上角并 `ClampWindowToWorkArea()`。
  - 底栏绘制：
    - layered/GDI+ 路径：`RenderLayeredWindow()` L1904 在 offwork 段之后画
      “今日已赚” + 金额 + 进度条（复用 `DrawWidgetText`）。
    - composition 路径：见下。
- `windows/src/windows/runtime/widget_text_cache.h/.cpp`
  - `WidgetTextSlot` 增加 `Encourager`（建议一个复合槽：label+amount+bar
    一次栅格化，减少 renderer 改动）；`WidgetTextInput` 增加
    `encouragerLabel`、`encouragerAmount`、`encouragerProgress`、
    `encouragerVisible`；校验长度/可见性/进度 0..1。
- `windows/src/windows/runtime/client_display.cpp`
  - `kSlots[]` 增加 `Encourager`；`DrawLatest()` 的 draw order 在
    `Countdown` 之后；`TextQuad` 的 y 偏移按 `MainWindowDipHeight` 布局。
  - 若复合槽方案不可行：给 `d3d11_renderer`/`composition_presenter` 增加
    一个纯色 quad 画进度条，文本仍走两个槽；改动更大，优先级低。
- `windows/src/windows/app.cpp` 设置
  - 新增 `kEncouragerEnable/Wage/Currency/Override/StartHour/StartMinute/
    EndHour/EndMinute` 控件，仿 `OffworkDialogProcedure` L~4650 的
    `CreateWindowExW` 模态对话框。
  - 金额输入：`ExponentForCode()` + 解析到最小单位（拒绝负/多小数点）；
    日薪 0 或 `!Window.Valid()` 时提示并拒绝保存。
  - 保存：写侧车 `encourager` 块；`gEncouragerActive = enabled && wage>0 &&
    Window.Valid()`；`ResizeRegionLayout()`；启动/停止 1s 定时器。
  - 菜单：`kMenuEncourager = 12`，“上班鼓励器…”打开设置。
- 计时
  - `kReminderTimer`（1s，L5242）里调用 `RefreshEncourager()`：
    `GetLocalTime` → `second_of_day` → `encourager::Evaluate(...)`；
    金额用 `FormatAmountMinor(status.earned_minor, exponent, symbol)`；
    进度用 `status.progress`；只在文本/进度变化时 `RenderLayeredWindow`。
  - 零点归零由 `Evaluate` 的 `second_of_day` 自然完成；跨午夜时段
    `Window.Valid()` 拒绝，不做跨天累计。
- 货币
  - `CurrencyForLanguage(ui_language)` 给默认；`currency_override` 时用
    用户选择的 ISO 代码；`ExponentForCode`/`SymbolForCode` 展示。
  - 侧车 `encourager.currency` 始终写 ISO 4217；覆盖开关单独存。

**验收**

- 09:00–18:00、日薪 100 元：13:30 显示 50.00；18:00 显示 100.00；
  18:00 后不再涨；08:59 显示 0；次日 00:00 归零。
- 进度条与 `elapsed/total` 一致；时段外暂停。
- 日薪 0 / 关闭 → 不显示底栏，窗口高度回落。
- 四种语言货币符号/小数位正确（CNY/TWD/USD 2 位，JPY 0 位）。

---

### 3.6 B3 · F3 勋章

**改动**

- `windows/src/windows/app.cpp`
  - `AppState` 增加 `std::map<std::string, niuma::medal::Earned> medalEarned;`
    `bool medalDirty; bool medalsBackfilled;`
  - 启动：`LoadMedalsState()`（侧车 `medals.earned`，兼容旧侧车只有
    `first_earned_day/count`、没有 `last_period` 的记录；`lit = count>0 ||
    first_earned_day非空`）。
  - `BackfillMedalsFromHistory()`：
    - 在 `InitializeDataStorage()` 与 `LoadInputLedger()` 都完成后执行
      （此时旧 `[daily]` 已完整加载）；
    - 收集 `gDataStorage.model->current().counts.daily` + pending 日，过滤
      `curve::ParseDateKey`，`std::sort`；
    - 调 `medal::BackfillHistory(&medalEarned, BuiltinThresholds(), days, lookup)`；
    - 幂等守门：侧车 `migration.medals_backfilled=true` 先写再补授
      （与 macOS `backfillMedalsFromHistory` 一致，防止重放重复计次）。
  - `EvaluateMedals()`：
    - 在 `ApplyInputView()`（L2775）检测到 `countsChanged` 时、`kDayTimer`
      跨天时、以及侧车加载后调用；
    - 日值 = `ReadDailyTotal(today)`；周/月值 = `medal::SumRange(
      curve::WeekDayKeys/MonthDayKeys, ReadDailyTotal)`；
    - `EvaluatePeriod` ×3 + `UpdateAchievement`；变化则 `medalDirty=true`，
      flush 侧车，勋章墙可见时刷新。
  - 勋章墙：`ShowMedals()` 仿日历窗口，3×3 网格 + 集齐成就；每枚显示
    图标/周期/档位/首次获得日/次数；默认收起（从菜单打开）。
  - 分享：见 C1。
  - 阈值：`medal::BuiltinThresholds()` + 侧车 `thresholds_version =
    "builtin-2026-11-08"`；`.nmgmedal` 包加载作为独立后续（CONTRACT §7.4），
    本批先内置，接口留 `Thresholds` 注入点。
- `windows/src/windows/runtime/metrics_store.*`：`medals` 块读写。
- 测试：`medals_test` 已覆盖阈值/周期/去重/补授；再加
  `metrics_store_test` 的旧记录兼容（缺 `last_period`）。

**验收**

- 达标即点亮；同一自然周期只计 1 次；下一周期再达标 count+1；
  首次获得日不变；值回落不撤销。
- 周一–周日、月初/月末、跨年周正确（单测已覆盖）。
- 历史补授只执行一次；补授不弹窗、不写曲线。
- 9 枚全亮 → `achievement.all` 点亮，首次日=最后一天。

---

### 3.7 B4 · F1 形象大小

**改动**

- `windows/src/windows/app.cpp`
  - `AppState` 增加 `double appearanceScale = 1.0;`
  - 常量 `kMinAppearanceScale=0.6`、`kMaxAppearanceScale=1.8`、
    `kDefaultAppearanceScale=1.0`。
  - 主窗口尺寸：`kWindowDipWidth/Height` 乘 `appearanceScale`；
    `MainWindowDipHeight()` 的底栏高度是否随缩放（F1 要求窗口/角色/气泡
    一起缩放；底栏文字也应等比，建议统一乘 scale）。
  - `ApplyWindowDpi()`/`ResizeRegionLayout()`/`ClampWindowToWorkArea()`
    重新按屏幕可用区钳位；极限档不出屏。
  - 命中/拖动区：`alpha_region`/`native_region_bands` 由窗口尺寸推导，
    确认随 scale 更新；`client_display.pixelScale = windowWidth / 240` 已自动跟随。
  - 气泡：`ReminderBubbleHeight`/字体按 scale 调整（F1 要求气泡一起缩放）。
  - 设置：外观选择器/设置里加 `msctls_trackbar32` 滑块（60–180，连续），
    拖动实时预览（改 `appearanceScale` → `ResizeRegionLayout()` +
    `RenderLayeredWindow()`），保存到侧车 `prefs.appearance_scale`。
  - 启动读取侧车；缺失/非法回落 1.0；旧 `data.ini` 不写新键。
- `windows/src/client/core/storage_state.*`：不改；F1 不进 `data.ini`。
- `windows/src/windows/runtime/client_display.*`：无需改（`pixelScale` 已由
  窗口宽度推导）；确认 `WidgetTextCache` 的 2 MiB 预算在放大后仍够。

**风险/待拍板**：REQUIREMENTS F1 R-F1-3 写“win data.ini”，CONTRACT §1.2/§3
要求 0.9.6 新偏好进侧车。建议按 CONTRACT 走侧车（避免 0.9.5 整文件重写覆盖），
在 S0/主控确认后执行。

**验收**

- 60%/100%/180% 三档；拖动实时；重启保持；极限档不出屏、点得中。
- 设置/日历/勋章/曲线窗口保持可读尺寸，不随主 widget 缩放。
- 繁中/日文不破版。

---

### 3.8 C1 · F3/F4 分享图（单张 PNG）

**新增** `windows/src/windows/runtime/share_card.h/.cpp`

- 只接收 CONTRACT §8.1 白名单模型：`schema_version=1`、`kind`、
  `locale`、`app_version`、`generated_on`（仅日期）、`title/subtitle/footer`、
  `merit`、`medal`、`curve`（仅渲染用，不落盘）、`money`。
- 渲染：GDI+ 画布 → WIC PNG 编码（`windowscodecs` 已链接）；不写 EXIF/
  文本块；单文件、无 sidecar；保存对话框用 `comdlg32`（已链接）。
- 禁止字段：本机路径、账号/设备标识、96 桶原始数组/事件流/精确时间戳、
  日薪原始值（除派生金额）。导出前做一次字段白名单断言/单测。
- F3：勋章墙“生成分享图”按钮；F4：曲线窗口“生成分享图”按钮。
- 测试：`share_card_test.cpp` 校验模型字段、PNG 无文本块、无路径/桶数组。

---

### 3.9 C2 · L1–L4 四语 UI 与安装器

**现状**

- `app.cpp:175 UiText(chinese, english)` 仅中/英；`IsChineseUi()` 只看
  `PRIMARYLANGID`。
- 共享头 `windows/src/reminder_policy.h` 与 `reminder_catalog_update.h` 已是
  四语泛化版本（与 macOS 逐字节一致），Windows 只需消费 `Locale`。
- 安装器 `niuma-merit.iss`：`[Languages]` 只有 english/chinesesimp/
  chinesetraditional，且 chinesetraditional 指向 `ChineseSimplified.isl`；
  没有日语；`ShowLanguageDialog=no`。

**改动**

- 新增 `windows/src/windows/runtime/ui_text_table.h/.cpp`
  - `enum class UiLanguage { ZhHans, ZhHant, Ja, En }`；
  - 系统语言检测：`GetUserDefaultUILanguage()` → `LocaleFromLanguageTag`
    或 `PRIMARYLANGID/LANGID` 映射；无法识别回落 `zh-Hans`；
  - 侧车 `prefs.ui_language` 可覆盖（设置里切换语言）；
  - `UiText(key)` 查表，四语缺键回落 `zh-Hans`；保留旧 `UiText(zh,en)`
    适配层直到全部调用点迁移。
- `app.cpp`：把所有 `UiText(L"中文", L"English")` 调用点改成 key 查表
  （量大，建议脚本/分批；先做菜单/设置/勋章/曲线/鼓励器/自检/隐私）。
- 字体/布局：繁中/日文用 `Microsoft YaHei UI`/`Yu Gothic UI` 回退；
  对话框宽度按最长语言测量，避免截断。
- 安装器：
  - `windows/installer/languages/TraditionalChinese.isl`（新增，正确繁中）；
  - `windows/installer/languages/Japanese.isl`（新增）；
  - `niuma-merit.iss` `[Languages]` 修正 chinesetraditional 指向，
    加 japanese；`ShowLanguageDialog=yes`（或保留自动检测 + 四语可选）；
  - 隐私声明补充：全局键鼠钩子只计次数/距离、不保存键值/坐标/窗口；
    曲线/勋章/鼓励器数据仅本地 `metrics-096.json`；不联网；
  - `AppVersion` 已由 `VERSION` 注入（0.9.6），无需硬编码；
  - `startup-choice.iss` 检查是否需要新页面/文案；
  - `windows/src/windows/app.rc` 版本资源已由 `app_version.h.in` 注入，
    只需确认 ProductVersion/FileVersion 为 0.9.6。
- CI：`.github/workflows/build.yml` 不在 `windows/**`，需主控/CI owner
  增加 Windows 测试 job（见 D1）。

**验收**

- 四语菜单/设置/勋章/曲线/鼓励器/自检无缺键；未知系统语言回落 zh-Hans。
- 安装器四语可选；繁中/日语安装界面无截断；隐私文案与 README 一致。

---

## 4. 文件级改动清单（按文件汇总）

### 4.1 `windows/src/windows/app.cpp`（主战场）

| 功能 | 位置/函数 | 改动 |
| --- | --- | --- |
| F0 回退 | `kScrollGestureGapMs` L141、`CountScrollGesture` L2353、`MouseHook` L2731、`CountGlobalDelivery` L2762、自检文案 L3066/L3100 | 距离计数 + delta 投递 + 文案 |
| F1 | `AppState` L215、`MainWindowDipHeight` L509、`ResizeOffworkWindow` L4646、`ClampWindowToWorkArea` L~4600、`ShowAppearancePicker` L4386 | scale/滑块/钳位/命中 |
| F2 | `MeritScene` L192、`DrawSceneArtwork` L1665、`DrawScene` L1738、`RenderLayeredWindow` L1904、`RenderCompositionWindow` L1836、`ShowContextMenu` L4931、`WM_TIMER` L5242、启动 L5692 | 场景/底栏/设置/1s 刷新 |
| F3 | `ApplyInputView` L2775、`WM_TIMER` L5242、`ShowContextMenu` L4931、启动 L5692 | 勋章求值/墙/补授/菜单 |
| F4 | `ShowMeritCalendar` L4085 旁、`ShowContextMenu` L4931、`WM_TIMER` L5242 | 曲线窗口/菜单/60 天 flush |
| 侧车 | `InitializeDataStorage` L860、`SaveState` L1539、`BeginClientClose` L~5060、`DataPath` L794 | metrics store 生命周期 |
| L1–L4 | `UiText` L175 及全部调用点、`WindowTitle` L181、`ShowContextMenu` L4931 | 四语查表 |

> `app.cpp` 已约 5900 行。若 F3/F4 窗口继续内联会让文件失控，建议把纯绘制/布局
> 抽到 `windows/src/windows/medal_view.cpp/.h`、`curve_view.cpp/.h`，`app.cpp`
> 只保留窗口生命周期与数据装配。抽取时不要改 `ui_theme.h` 的公共 API。

### 4.2 `windows/src/windows/runtime/input_service.h/.cpp`

- `Impl` 增加 `ScrollTickCounter`、`lastScrollMs/hasScroll`。
- `Mouse()` 解析 `MSLLHOOKSTRUCT::mouseData` 的 wheel delta；`WM_MOUSEWHEEL`
  与 `WM_MOUSEHWHEEL` 都处理。
- `Observe()` 自检 expected/counted 按 ticks 计。
- `InputCommandKind::MarkCurveObserved`（F4 心跳）。
- `InputServiceSnapshot` 不新增曲线数据（走 ledger）。
- 监听器重启/停止时重置滚动手势。

### 4.3 `windows/src/client/core/input_state.h/.cpp`

- `InputEvent` 增加 `scroll_ticks`、`minute_of_day`。
- `Observe` 的 Scroll 分支按 ticks 计数；删除 180ms 手势去抖
  （`StartsScrollGesture`/`kScrollGestureGapMs`）。
- 新增 64 天曲线环 + `MarkCurveObserved` + `CopyCurveDays`。
- `Count` → `CountOperations(n)`，保持 total/today/动画序列的原子更新。
- 不引入平台头；仍可被 `clang++` 单测。

### 4.4 `windows/src/client/core/ledger_snapshot.h`

- `LedgerSnapshotResult` 增加 `curve` 向量；`LedgerSnapshotChannel` 预分配
  `curveBuffer_`（64 条），`ProduceIfRequested`/`TryConsume` 同步复制。
- 保持“ledger 只在 owner 侧、回调不复制”的现有约束。

### 4.5 `windows/src/windows/runtime/client_display.h/.cpp`

- `ClientDisplayState` 增加 F2 的 label/amount/progress（或复用
  `WidgetTextInput` 新字段）。
- `kSlots[]`/draw order 增加 `Encourager` 槽；`DrawLatest` 计算底栏 y 偏移。
- F3/F4 不进入主 widget 渲染（独立 GDI+ 窗口）。

### 4.6 `windows/src/windows/runtime/widget_text_cache.h/.cpp`

- `WidgetTextSlot` 增加 `Encourager`；`WidgetTextInput` 增加对应字段。
- `ValidInput`/`KeyFor`/`Update` 增加分支；长度上限（金额 ≤32、label ≤128）。
- 2 MiB 像素预算复核：多一个槽后仍要能容纳最长金额 + 96 桶曲线窗口
  （曲线窗口不在此缓存，实际压力不大）。

### 4.7 `windows/src/windows/runtime/d3d11_renderer.*` / `composition_presenter.*`

- 优先用“复合文本槽”方案，不改 renderer；若进度条必须独立几何，再加一个
  纯色 quad 类型（positions + color + scissor），不要引入 D2D。
- 纹理 key 仍用 `kTextKey + slot`；新增槽不能与已有 key 冲突。

### 4.8 `windows/src/windows/runtime/storage_service.*` / `storage_state.*`（`data.ini`）

`data.ini` 路径由 `app.cpp:794 DataPath()` 给出（`%LOCALAPPDATA%\NiuMaMerit\data.ini`；
隔离验收模式在 `gAcceptanceRoot` 下）。0.9.6 **只读兼容**，不新增键：

| 旧键 | 0.9.6 用途 | 改动 |
| --- | --- | --- |
| `[state] total` | 总功德展示/分享卡 | 只读 |
| `[daily] <date>` | 日历、勋章日/周/月归集、曲线周/月视图 | 只读，仍是权威来源 |
| `[state] x/y` | 位置记忆 | 只读；F1 缩放后重新钳位 |
| `[state] selected_scene` / `selected_pack_id` | 形象选择 | 只读；F2 若用 scene 4 需把 L257 钳制改 0..4 |
| `[state] autostart_*` / `privacy_shown` / `basic_guide_shown` / `auto_hide_fullscreen` | 既有设置 | 行为不变 |
| `[offwork] enabled/hour/minute`、`[offwork_daily]` | 下班倒计时 | 只读/原逻辑写回，行为不变 |

- `MakeChanges()` 不新增 0.9.6 键；`data.ini` 保持 0.9.5 可回退。
- `StorageState` 不承载侧车数据；侧车由 `MetricsStore` 独立 worker 管理。
- 若 F1 选择 data.ini（不推荐），才改 `StorageAppearance`/`MakeChanges`；
  按 CONTRACT 走侧车则不改。

### 4.9 `windows/src/windows/runtime/metrics_store.h/.cpp`（新增）

- 见 A1；独立 worker、原子写、坏块降级、1 MiB、未知字段保留。
- 建议在 `CMakeLists.txt` 单独 target `niuma-windows-metrics`，链接
  `niuma-runtime-core`/`Threads`，不依赖 GDI/D3D。

### 4.10 `windows/src/windows/runtime/share_card.h/.cpp`（新增）

- 见 C1；WIC PNG + GDI+；白名单模型；无 EXIF/文本块。

### 4.11 `windows/installer/*`

- `niuma-merit.iss`：四语 `[Languages]`、隐私文案、版本（已 0.9.6）、
  可选 `.nmgmedal` 示例包（若随安装包分发）。
- `languages/TraditionalChinese.isl`、`languages/Japanese.isl`（新增）。
- `startup-choice.iss`：确认新功能不改变启动项/隐私页流程。

### 4.12 `windows/CMakeLists.txt`

- 新增 `metrics_store.cpp`/`share_card.cpp`/`ui_text_table.cpp` 到对应 target。
- 可选 `option(NIUMA_BUILD_TESTS ...)`：把 `windows/tests/*.cpp` 编成
  CTest target（仅标准 C++，MSVC/clang 都可）；不默认开启，避免影响正式构建。

---

## 5. 测试与验收

### 5.1 纯逻辑（本批已 PASS）

```sh
windows/tests/run_tests.sh
# work_encourager_test: OK (12416 checks)
# merit_curve_test:    OK (477 checks)
# medals_test:         OK (111 checks)
# scroll_tick_counter_test: OK (1227 checks)
```

`NIUMA_TEST_SANITIZE=1` 下同样全 PASS（ASan/UBSan）。

### 5.2 第二批新增单测

- `windows/tests/input_state_test.cpp`：F0 ticks、F4 桶/心跳、日期切换。
- `windows/tests/metrics_store_test.cpp`：JSON 往返、坏块、原子恢复、
  1 MiB、>2^53、未知字段。
- `windows/tests/share_card_test.cpp`：白名单、PNG 无文本块。
- 现有四个测试保持全 PASS（改动头文件时同步跑）。

### 5.3 Windows CI（需 `.github` owner）

- `cmake -S windows -B windows/build -A x64` + `niuma-merit` 构建。
- 增加 `niuma-tests`（或 `ctest`）在 windows-latest 上跑纯逻辑测试。
- 增加 macOS/Ubuntu job 用 clang++ 跑 `windows/tests/run_tests.sh`（跨平台
  纯逻辑回归，防止 Windows 头被平台代码污染）。

### 5.4 实机验收（Windows VM/真机）

| 功能 | 用例 |
| --- | --- |
| F0 | 慢滚、快滚、触控板滑动、触控板轻点；惯性不无限涨；自检文案 |
| F1 | 60/100/180%；拖动实时；重启保持；极限档不出屏；命中/拖动 |
| F2 | 09:00/13:30/18:00/次日 00:00；时段外；日薪 0；四语货币 |
| F3 | 日/周/月达标；跨周/月/年；同周期去重；历史补授；分享图 |
| F4 | 96 桶边界；coverage 真零/未采集；三视图；60 天滚删；分享图 |
| 侧车 | 截断/坏块/杀进程/回退 0.9.5 再升级对账 |
| L1–L4 | 四语界面无缺键；安装器四语；隐私文案 |

---

## 6. 风险与待拍板

1. **`selected_scene` 4 vs CONTRACT §3 的 0..3**：macOS S1 已用
   `MeritSceneEncourager = 4` / `builtin.encourager`。Windows 若跟随，需要
   把 `storage_service.cpp` 的钳制改为 0..4，并在 CONTRACT 里补一句；
   否则 F2 场景无法持久化。**需 S0/主控确认。**
2. **F1 持久化位置冲突**：REQUIREMENTS 写 `data.ini`，CONTRACT §1.2/§3 写侧车。
   建议按 CONTRACT 走 `metrics-096.json` 的 `prefs.appearance_scale`；需确认。
3. **滚动常量校准**：`kMaxTicksPerEvent=4`、`kMaxTicksPerGesture=30`、
   `kIdleGestureGapMs=350` 与 macOS 对齐，但 Windows 实机滚轮/触控板
   可能需调整；只改 `scroll_tick_counter.h` 一处，双端同步。
4. **`JsonParser` 不能直接复用**：`reminder_catalog_update.h` 的解析器只收
   int64 整数、拒绝 `1.0`；侧车需要支持字符串 uint64 和字符串小数。
   不要为了复用去改共享头（任务禁止），在 `metrics_store` 内实现小解析器。
5. **曲线数据放哪**：建议 `InputCore` 64 天环 + ledger 复制；若主控希望
   曲线完全走 UI 侧增量 map，需要重新评估“输入回调不分配”的约束。
6. **`.nmgmedal` 包**：CONTRACT §7.4 要求阈值/图标可外置。本计划先内置
   阈值（`builtin-2026-11-08`）+ 预留 `Thresholds` 注入；若 0.9.6 必须支持
   外部勋章包，需要把 `miniz` ZIP 校验/签名/图标加载加进 B3，工期 +2–3 天。
7. **安装器四语**：需要新增/校对繁中、日语 `.isl`，并改
   `ShowLanguageDialog`；文案需产品/法务确认（尤其输入监控隐私说明）。
8. **无 MSVC 本机验证**：所有平台胶水必须在 Windows CI/VM 编译通过；
   本机只能验证纯逻辑。合并前至少一次 `windows-latest` 构建 + 实机冒烟。
9. **D2D 术语**：仓库当前没有 D2D；主窗口是 D3D11 composition + GDI+
   layered fallback。F2 底栏优先走现有文本槽/四边 quad，不新增 D2D 依赖。

---

## 7. 提交与发布边界

- 本批（纯逻辑）单独 commit，便于主控 cherry-pick/对拍。
- 第二批按 P2-A/B/C/D 分 commit；每个 commit 自带测试或验收说明。
- 不 push、不签名、不合并 `main`；由主控统一推送。
- 发布前检查：`windows/VERSION=0.9.6`、安装器版本、`app.rc` 版本资源、
  `metrics-096.json` 1 MiB 上界、四语安装器、F0 四场景实机记录。
