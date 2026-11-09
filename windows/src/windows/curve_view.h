#pragma once

// F4 · 牛马曲线窗口（GDI+ 独立窗口，不进入主 widget 的 D3D11 文本缓存）。
//
// 三视图：日（96 个 15 分钟桶，未采集区与真零区分）、周（周一–周日每日总）、
// 月（当月每日总）。日视图数据来自侧车 curve.days；周/月视图数据来自旧
// data.ini [daily] 的日总数（权威来源，CONTRACT §6）。
//
// 本模块只做绘制与窗口生命周期。数据装配由 app.cpp 通过 CurveViewData 注入，
// 避免把长段 GDI+ 代码堆进 app.cpp（PHASE2_PLAN §4.1 建议抽出）。
//
// 编译期依赖：GDI+（gdiplus）、windowscodecs、comdlg32（PNG 导出）。仅 Windows。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace niuma::windows::window {

// 曲线窗口「导出分享图」按钮 → owner（主窗口）的自定义消息。app 层在
// WindowProcedure 中处理（WM_APP + 90，避开 app.cpp 已用的编号）。
constexpr UINT kCurveExportMessage = WM_APP + 90;

enum class CurveViewMode : int { Day = 0, Week = 1, Month = 2 };

// 一次快照：app.cpp 在打开/刷新时装配。
struct CurveViewData {
  CurveViewMode mode = CurveViewMode::Day;
  // 标题用的本地日期。
  int year = 1970;
  int month = 1;
  int day = 1;
  std::wstring todayKey;                // "YYYY-MM-DD"
  std::uint64_t todayTotal = 0;         // 旧 [daily] 今日总数（仅日视图展示用）
  // 日视图：96 桶 + 覆盖位图（coverage[i] 为 true 表示已采集）。
  std::vector<std::uint64_t> dayBuckets;  // 恰好 96 项（空表示今日尚未采集）
  std::vector<bool> dayCoverage;          // 恰好 96 项
  bool dayPartial = false;                // 升级当天部分采集（日总 > 桶和）
  // 周/月视图：每日总（按 keys 顺序）。
  std::vector<std::wstring> rangeLabels;  // 显示标签（周：一..日；月：1..31）
  std::vector<std::uint64_t> rangeValues;
};

// 打开或刷新曲线窗口。owner 为主窗口。data 为最新的数据快照。
void ShowCurveWindow(HWND owner, const CurveViewData& data);

// 当前曲线窗口的视图模式（未打开时返回 Day）。
CurveViewMode CurrentCurveMode();

// 当前窗口是否打开（用于定时刷新）。
bool CurveWindowOpen();
void RefreshCurveWindow(const CurveViewData& data);
void CloseCurveWindow();

// 把当前曲线快照导出为单张 PNG（白名单模型，无路径/账号/原始桶数组文本块）。
// 返回 true 表示已写出文件；false 表示用户取消或失败（失败时由 app 层提示）。
// suggestedName 为保存对话框默认文件名（不含路径）。
bool ExportCurvePng(HWND owner, const CurveViewData& data,
                    const std::wstring& suggestedName, const std::wstring& titleZh,
                    const std::wstring& titleEn, bool chinese,
                    std::wstring* errorOut);

}  // namespace niuma::windows::window
