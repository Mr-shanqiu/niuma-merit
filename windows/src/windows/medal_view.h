#pragma once

// F3 · 勋章与成就窗口（GDI+ 独立窗口，不进入主 widget 渲染）。
//
// 内容：3×3 勋章墙（日/周/月 × 铜/银/金）+ 集齐成就；默认收起，由菜单打开后
// 用户点「展开勋章墙」；每枚显示图标/周期/档位/首次获得日/次数 或 阈值。
// 分享图复用 F4 的 PNG 底层（ExportSharePng，白名单模型，CONTRACT §8）。
//
// 数据装配在 app.cpp，本模块只做绘制与窗口生命周期。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <array>
#include <cstdint>
#include <string>

namespace niuma::windows::window {

struct MedalCell {
  std::wstring key;            // "day.bronze" ... "month.gold"
  std::wstring periodLabel;    // 日/周/月
  std::wstring tierLabel;      // 铜/银/金
  std::uint64_t threshold = 0;
  std::uint64_t currentValue = 0;  // 本周期累计（用于进度提示）
  bool lit = false;
  std::wstring firstEarnedDay;
  std::uint32_t count = 0;
};

struct MedalViewData {
  std::array<MedalCell, 9> cells{};  // 行=周期(日/周/月)，列=档位(铜/银/金)
  bool achievementLit = false;
  std::wstring achievementFirstDay;
  int litCount = 0;
  std::wstring thresholdsVersion;    // "builtin-2026-11-08"
  std::wstring dayLabel;             // 本地化的周期名（用于分享 subtitle）
  // 分享图页脚/标题。
  std::wstring productName;
};

void ShowMedalWindow(HWND owner, const MedalViewData& data);
bool MedalWindowOpen();
void RefreshMedalWindow(const MedalViewData& data);
void CloseMedalWindow();

// FB10/D22 · 修行等级窗口（替代旧勋章墙，与 mac 对齐）。
struct CultivationViewData {
  int level = 0;                 // 0-based
  std::wstring title;            // 当前称号
  std::wstring meritText;        // 累计功德文案
  std::wstring subtitle;         // 距下一级/圆满
  double progress = 0.0;         // 0..1
  bool maxLevel = false;
  std::array<std::wstring, 6> levelTitles{};
  std::array<std::uint64_t, 6> levelThresholds{};
};
void ShowCultivationWindow(HWND owner, const CultivationViewData& data);

}  // namespace niuma::windows::window