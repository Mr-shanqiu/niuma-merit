#pragma once

// FB10/D22 · 修行等级窗口（GDI+ 独立窗口，替代旧勋章墙，与 mac 对齐）。
// 数据装配在 app.cpp，本模块只做绘制与窗口生命周期。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <array>
#include <cstdint>
#include <string>

namespace niuma::windows::window {

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
