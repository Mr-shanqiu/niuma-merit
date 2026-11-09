// F3 · 勋章与成就窗口实现（GDI+ 绘制 + 分享图复用 curve_view 的 PNG 底层）。
#include "medal_view.h"

#include <windowsx.h>
#include <objidl.h>
#include <propidl.h>
#include <wincodec.h>
#include <commdlg.h>
#include <gdiplus.h>

#include "curve_view.h"
#include "ui_theme.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace niuma::windows::window {

namespace {

constexpr wchar_t kMedalClass[] = L"NiuMaMeritMedals";
constexpr int kMedalToggle = 4501;
constexpr int kMedalShareCombo = 4502;
constexpr int kMedalExport = 4503;
constexpr int kMedalClose = 4504;
constexpr float kMedalWidth = 720.0f;
constexpr float kMedalHeight = 820.0f;

struct MedalWindowState {
  HWND window = nullptr;
  MedalViewData data;
  bool hasData = false;
  bool expanded = false;   // 默认收起
  int shareIndex = 0;      // 已点亮勋章的索引（data.cells 下标；9 = 集齐成就）
};

MedalWindowState gMedals;

bool ChineseUi() { return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE; }

const wchar_t* Ui(const wchar_t* zh, const wchar_t* en) { return ChineseUi() ? zh : en; }

const wchar_t* MedalFontFamily() {
  static const wchar_t* available = [] {
    for (const auto* name : {L"Microsoft YaHei UI", L"Microsoft YaHei", L"Segoe UI"}) {
      Gdiplus::FontFamily family(name);
      if (family.GetLastStatus() == Gdiplus::Ok) return name;
    }
    return L"Segoe UI";
  }();
  return available;
}

void DrawText(Gdiplus::Graphics& graphics, const std::wstring& text,
              const Gdiplus::RectF& rect, float size, const Gdiplus::Color& color,
              bool bold = false,
              Gdiplus::StringAlignment alignment = Gdiplus::StringAlignmentNear) {
  Gdiplus::StringFormat format;
  format.SetAlignment(alignment);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  float fitted = size;
  while (fitted > 8) {
    Gdiplus::Font font(MedalFontFamily(), fitted,
                       bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                       Gdiplus::UnitPixel);
    Gdiplus::RectF measured;
    graphics.MeasureString(text.c_str(), -1, &font, Gdiplus::PointF(0, 0), &measured);
    if (measured.Width <= rect.Width) break;
    fitted -= 1;
  }
  Gdiplus::Font font(MedalFontFamily(), fitted,
                     bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                     Gdiplus::UnitPixel);
  Gdiplus::SolidBrush brush(color);
  graphics.DrawString(text.c_str(), -1, &font, rect, &format, &brush);
}

std::wstring Number(std::uint64_t value) {
  auto text = std::to_wstring(value);
  for (int i = static_cast<int>(text.size()) - 3; i > 0; i -= 3)
    text.insert(static_cast<size_t>(i), 1, L',');
  return text;
}

std::wstring TierIcon(int tier) {
  if (tier == 0) return L"\u25CF";   // ● 铜
  if (tier == 1) return L"\u25C6";   // ◆ 银
  return L"\u2605";                  // ★ 金
}

void PaintMedals(Gdiplus::Graphics& graphics, const MedalViewData& data, bool expanded) {
  const float W = kMedalWidth;
  graphics.Clear(Gdiplus::Color::White);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);
  const Gdiplus::Color ink(255, 29, 29, 31), muted(255, 110, 110, 115),
      accent(255, 240, 139, 35), rule(255, 233, 233, 236),
      lockedFill(255, 246, 246, 248), litFill(255, 253, 242, 224);

  DrawText(graphics, Ui(L"勋章与成就", L"Medals & Achievements"),
           Gdiplus::RectF(28, 20, W - 56, 38), 24, ink, true);
  wchar_t summary[160] = {};
  swprintf_s(summary, std::size(summary),
             Ui(L"已点亮 %d / 9 枚勋章 · 集齐成就：%s", L"Unlocked %d / 9 medals · Collector: %s"),
             data.litCount, data.achievementLit ? Ui(L"已达成", L"Achieved")
                                                : Ui(L"未达成", L"Not yet"));
  DrawText(graphics, summary, Gdiplus::RectF(28, 62, W - 56, 26), 15, muted, false);

  if (!expanded) {
    DrawText(graphics, Ui(L"勋章墙默认收起。勾选上方「展开勋章墙」查看九枚勋章与集齐成就。",
                          L"The medal wall is collapsed by default. Tick “Show medal wall” above to see all nine medals and the collector achievement."),
             Gdiplus::RectF(28, 140, W - 56, 90), 14, muted, false);
  } else {
    const float left = 28, top = 124;
    const float cellW = (W - 56 - 24) / 3.0f, cellH = 140.0f;
    for (int row = 0; row < 3; ++row) {
      for (int col = 0; col < 3; ++col) {
        const int index = row * 3 + col;
        const MedalCell& cell = data.cells[static_cast<std::size_t>(index)];
        const Gdiplus::RectF rect(left + col * (cellW + 12), top + row * (cellH + 12),
                                  cellW, cellH);
        Gdiplus::GraphicsPath path;
        niuma::ui::RoundPath(path, rect, 10.0f);
        Gdiplus::SolidBrush fill(cell.lit ? litFill : lockedFill);
        Gdiplus::Pen border(cell.lit ? Gdiplus::Color(255, 226, 196, 150)
                                     : Gdiplus::Color(255, 228, 228, 232), 1.0f);
        graphics.FillPath(&fill, &path);
        graphics.DrawPath(&border, &path);
        DrawText(graphics, TierIcon(col) + L" " + cell.periodLabel + L" · " + cell.tierLabel,
                 Gdiplus::RectF(rect.X + 12, rect.Y + 8, rect.Width - 24, 24), 14,
                 cell.lit ? ink : muted, true);
        if (cell.lit) {
          DrawText(graphics, Ui(L"已点亮", L"Unlocked"),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 40, rect.Width - 24, 20), 12,
                   accent, true);
          DrawText(graphics, (Ui(L"首次 ", L"First ")) +
                     (cell.firstEarnedDay.empty() ? L"\u2014" : cell.firstEarnedDay),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 64, rect.Width - 24, 20), 12, muted,
                   false);
          DrawText(graphics, (Ui(L"次数 ×", L"Times ×")) + std::to_wstring(cell.count),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 88, rect.Width - 24, 20), 12, muted,
                   false);
          DrawText(graphics, Ui(L"本期 ", L"This period ") + Number(cell.currentValue),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 110, rect.Width - 24, 20), 12, muted,
                   false);
        } else {
          DrawText(graphics, Ui(L"未点亮", L"Locked"),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 40, rect.Width - 24, 20), 12, muted,
                   true);
          DrawText(graphics, Ui(L"阈值 ", L"Threshold ") + Number(cell.threshold),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 64, rect.Width - 24, 20), 12, muted,
                   false);
          const double progress = cell.threshold == 0 ? 0.0
              : std::min(1.0, static_cast<double>(cell.currentValue) /
                              static_cast<double>(cell.threshold));
          Gdiplus::SolidBrush track(Gdiplus::Color(255, 228, 228, 232));
          Gdiplus::SolidBrush bar(Gdiplus::Color(255, 240, 139, 35));
          const Gdiplus::RectF trackRect(rect.X + 12, rect.Y + 96, rect.Width - 24, 8);
          graphics.FillRectangle(&track, trackRect);
          if (progress > 0)
            graphics.FillRectangle(&bar, Gdiplus::RectF(trackRect.X, trackRect.Y,
                static_cast<Gdiplus::REAL>(trackRect.Width * progress), trackRect.Height));
          DrawText(graphics, Ui(L"本期 ", L"This period ") + Number(cell.currentValue),
                   Gdiplus::RectF(rect.X + 12, rect.Y + 110, rect.Width - 24, 20), 12, muted,
                   false);
        }
      }
    }
    // 集齐成就
    const Gdiplus::RectF ach(left, top + 3 * (cellH + 12), W - 56, 64);
    Gdiplus::GraphicsPath achPath;
    niuma::ui::RoundPath(achPath, ach, 10.0f);
    Gdiplus::SolidBrush achFill(data.achievementLit ? litFill : lockedFill);
    graphics.FillPath(&achFill, &achPath);
    const std::wstring achText = data.achievementLit
        ? (Ui(L"\u2605 集齐成就 · 已于 ", L"\u2605 Collector · achieved ") + data.achievementFirstDay)
        : Ui(L"\u2605 集齐成就 · 集齐 9 枚勋章后解锁", L"\u2605 Collector · unlocks after all nine medals");
    DrawText(graphics, achText, Gdiplus::RectF(ach.X + 16, ach.Y, ach.Width - 32, ach.Height),
             15, data.achievementLit ? ink : muted, data.achievementLit);
  }
  {
    Gdiplus::Pen rulePen(rule, 1);
    graphics.DrawLine(&rulePen, 28.0f, 650.0f, W - 28, 650.0f);
  }
  DrawText(graphics, Ui(
      L"勋章按自然日 / 自然周（周一–周日）/ 自然月归集，达到阈值即永久点亮并记录次数。"
      L"阈值为占位值（thresholds_version = ",
      L"Medals tally by natural day / week (Mon–Sun) / month; reaching a threshold permanently unlocks it and records the count. Thresholds are placeholders (thresholds_version = ") +
      data.thresholdsVersion + Ui(L"）。", L")."),
      Gdiplus::RectF(28, 662, W - 56, 46), 11, muted, false);
  DrawText(graphics, Ui(
      L"分享图由用户主动导出，单张 PNG，不含本机路径、账号或原始时段数据。",
      L"Share images are exported by the user as a single PNG with no local paths, account IDs, or raw interval data."),
      Gdiplus::RectF(28, 712, W - 56, 26), 11, muted, false);
}

float MedalScale(HWND window) {
  RECT client{};
  GetClientRect(window, &client);
  return std::max(0.1f, std::min(client.right / kMedalWidth, client.bottom / kMedalHeight));
}

void LayoutMedals(HWND window) {
  const float scale = MedalScale(window);
  const auto move = [&](int id, int x, int y, int w, int h) {
    MoveWindow(GetDlgItem(window, id), static_cast<int>(x * scale),
               static_cast<int>(y * scale), static_cast<int>(w * scale),
               static_cast<int>(h * scale), TRUE);
  };
  move(kMedalToggle, 28, 92, 260, 24);
  move(kMedalShareCombo, 28, 764, 300, 30);
  move(kMedalExport, 340, 764, 180, 30);
  move(kMedalClose, kMedalWidth - 120, 764, 92, 30);
}

void PaintMedalWindow(HWND window) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  RECT client{};
  GetClientRect(window, &client);
  if (dc && client.right > 0 && client.bottom > 0) {
    niuma::ui::PaintBuffered(dc, client, [&](HDC memory) {
      Gdiplus::Graphics graphics(memory);
      const float scale = MedalScale(window);
      graphics.ScaleTransform(scale, scale);
      PaintMedals(graphics, gMedals.data, gMedals.expanded);
      graphics.Flush(Gdiplus::FlushIntentionSync);
    });
  }
  EndPaint(window, &paint);
}

// 重建「分享哪一枚」下拉：只列已点亮的勋章 + 集齐成就。
void RebuildShareCombo(HWND window) {
  HWND combo = GetDlgItem(window, kMedalShareCombo);
  if (!combo) return;
  SendMessageW(combo, CB_RESETCONTENT, 0, 0);
  int firstSelectable = -1;
  for (int i = 0; i < 9; ++i) {
    const MedalCell& cell = gMedals.data.cells[static_cast<std::size_t>(i)];
    if (!cell.lit) continue;
    const std::wstring title = TierIcon(i % 3) + L" " + cell.periodLabel + L" · " + cell.tierLabel;
    SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(title.c_str()));
    const int item = static_cast<int>(SendMessageW(combo, CB_GETCOUNT, 0, 0)) - 1;
    SendMessageW(combo, CB_SETITEMDATA, item, i);
    if (firstSelectable < 0) firstSelectable = i;
  }
  if (gMedals.data.achievementLit) {
    SendMessageW(combo, CB_ADDSTRING, 0,
                 reinterpret_cast<LPARAM>(Ui(L"\u2605 集齐成就", L"\u2605 Collector Achievement")));
    const int item = static_cast<int>(SendMessageW(combo, CB_GETCOUNT, 0, 0)) - 1;
    SendMessageW(combo, CB_SETITEMDATA, item, 9);
  }
  const int count = static_cast<int>(SendMessageW(combo, CB_GETCOUNT, 0, 0));
  EnableWindow(combo, count > 0);
  EnableWindow(GetDlgItem(window, kMedalExport), count > 0);
  if (count > 0) SendMessageW(combo, CB_SETCURSEL, 0, 0);
  (void)firstSelectable;
}

void ExportSelectedMedal(HWND owner) {
  HWND combo = GetDlgItem(gMedals.window, kMedalShareCombo);
  if (!combo) return;
  const int selected = static_cast<int>(SendMessageW(combo, CB_GETCURSEL, 0, 0));
  if (selected < 0) return;
  const int index = static_cast<int>(SendMessageW(combo, CB_GETITEMDATA, selected, 0));
  const bool chinese = ChineseUi();
  ShareCardModel model;
  model.kind = ShareCardModel::Kind::Medal;
  model.title = gMedals.data.productName.empty()
      ? (chinese ? L"牛马电子功德" : L"NiuMa Merit")
      : gMedals.data.productName;
  model.footerProduct = model.title;
  model.footerWatermark = L"niuma-merit 0.9.6";
  model.hasMedal = true;
  if (index == 9) {
    model.medalAchievement = true;
    model.medalPeriod = chinese ? L"集齐成就" : L"Collector";
    model.medalTier = L"\u2605";
    model.medalEarnedDay = gMedals.data.achievementFirstDay;
    model.medalCount = 1;
    model.subtitle = chinese ? L"集齐成就 · 九枚勋章全部点亮"
                             : L"Collector Achievement · all nine medals unlocked";
  } else if (index >= 0 && index < 9) {
    const MedalCell& cell = gMedals.data.cells[static_cast<std::size_t>(index)];
    model.medalPeriod = cell.periodLabel;
    model.medalTier = cell.tierLabel;
    model.medalEarnedDay = cell.firstEarnedDay;
    model.medalCount = cell.count;
    model.medalValue = cell.currentValue;
    model.medalThreshold = cell.threshold;
    model.subtitle = cell.periodLabel + L" · " + cell.tierLabel;
  } else {
    return;
  }
  std::wstring error;
  if (!ExportSharePng(owner, model, L"niuma-merit-medal.png", chinese, &error)) {
    if (!error.empty())
      niuma::ui::Message(owner,
          chinese ? L"未能生成分享图，请稍后重试。"
                  : L"Could not generate the share image. Please try again.",
          model.title.c_str(), MB_OK | MB_ICONWARNING);
  }
}

LRESULT CALLBACK MedalWindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      PaintMedalWindow(window);
      return 0;
    case WM_PRINTCLIENT: {
      Gdiplus::Graphics graphics(reinterpret_cast<HDC>(wParam));
      const float scale = MedalScale(window);
      graphics.ScaleTransform(scale, scale);
      PaintMedals(graphics, gMedals.data, gMedals.expanded);
      graphics.Flush(Gdiplus::FlushIntentionSync);
      return 0;
    }
    case WM_SIZE:
      LayoutMedals(window);
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    case WM_DPICHANGED: {
      const auto* rect = reinterpret_cast<const RECT*>(lParam);
      SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left,
                   rect->bottom - rect->top, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_COMMAND: {
      const int id = LOWORD(wParam);
      if (id == IDCANCEL) {
        DestroyWindow(window);
        return 0;
      }
      if (id == kMedalToggle && HIWORD(wParam) == BN_CLICKED) {
        gMedals.expanded = SendMessageW(GetDlgItem(window, kMedalToggle), BM_GETCHECK, 0, 0) ==
            BST_CHECKED;
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      }
      if (id == kMedalExport) {
        ExportSelectedMedal(GetWindow(window, GW_OWNER) ? GetWindow(window, GW_OWNER) : window);
        return 0;
      }
      if (id == kMedalClose) {
        DestroyWindow(window);
        return 0;
      }
      return 0;
    }
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      gMedals.window = nullptr;
      return 0;
    default:
      break;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace

bool MedalWindowOpen() { return gMedals.window != nullptr && IsWindow(gMedals.window); }

void RefreshMedalWindow(const MedalViewData& data) {
  gMedals.data = data;
  gMedals.hasData = true;
  if (MedalWindowOpen()) {
    RebuildShareCombo(gMedals.window);
    InvalidateRect(gMedals.window, nullptr, FALSE);
  }
}

void CloseMedalWindow() {
  if (MedalWindowOpen()) DestroyWindow(gMedals.window);
}

void ShowMedalWindow(HWND owner, const MedalViewData& data) {
  gMedals.data = data;
  gMedals.hasData = true;
  if (MedalWindowOpen()) {
    RebuildShareCombo(gMedals.window);
    SetForegroundWindow(gMedals.window);
    InvalidateRect(gMedals.window, nullptr, FALSE);
    return;
  }
  WNDCLASSEXW medalClass = {};
  medalClass.cbSize = sizeof(medalClass);
  medalClass.lpfnWndProc = MedalWindowProcedure;
  medalClass.hInstance = GetModuleHandleW(nullptr);
  medalClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  medalClass.hbrBackground = nullptr;
  medalClass.lpszClassName = kMedalClass;
  RegisterClassExW(&medalClass);
  const UINT dpi = niuma::ui::Dpi(owner);
  const auto style = WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN;
  RECT desired{0, 0, niuma::ui::Dip(static_cast<int>(kMedalWidth), dpi),
               niuma::ui::Dip(static_cast<int>(kMedalHeight), dpi)};
  AdjustWindowRectEx(&desired, style, FALSE, 0);
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int width = std::min(desired.right - desired.left, work.right - work.left);
  const int height = std::min(desired.bottom - desired.top, work.bottom - work.top);
  const bool chinese = ChineseUi();
  gMedals.window = CreateWindowExW(
      0, kMedalClass, chinese ? L"勋章与成就" : L"Medals & Achievements", style,
      work.left + (work.right - work.left - width) / 2,
      work.top + (work.bottom - work.top - height) / 2, width, height, owner, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!gMedals.window) return;
  HWND toggle = CreateWindowExW(0, L"BUTTON",
      chinese ? L"展开勋章墙" : L"Show medal wall",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX, 0, 0, 1, 1, gMedals.window,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kMedalToggle)), GetModuleHandleW(nullptr),
      nullptr);
  SendMessageW(toggle, BM_SETCHECK, gMedals.expanded ? BST_CHECKED : BST_UNCHECKED, 0);
  CreateWindowExW(0, L"COMBOBOX", L"",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 1, 1,
      gMedals.window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(kMedalShareCombo)),
      GetModuleHandleW(nullptr), nullptr);
  CreateWindowExW(0, L"BUTTON", chinese ? L"导出分享图…" : L"Export Share Image…",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 1, 1, gMedals.window,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kMedalExport)), GetModuleHandleW(nullptr),
      nullptr);
  CreateWindowExW(0, L"BUTTON", chinese ? L"关闭" : L"Close",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 1, 1, gMedals.window,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kMedalClose)), GetModuleHandleW(nullptr),
      nullptr);
  niuma::ui::Apply(gMedals.window);
  LayoutMedals(gMedals.window);
  RebuildShareCombo(gMedals.window);
  niuma::ui::WindowChrome(gMedals.window);
  ShowWindow(gMedals.window, SW_SHOW);
  SetForegroundWindow(gMedals.window);
  SetFocus(gMedals.window);
  InvalidateRect(gMedals.window, nullptr, FALSE);
}

}  // namespace niuma::windows::window