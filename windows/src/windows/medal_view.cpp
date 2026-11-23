// FB10/D22 · 修行等级窗口实现（GDI+ 绘制，替代旧勋章墙）。
#include "medal_view.h"

#include <windowsx.h>
#include <objidl.h>
#include <propidl.h>
#include <wincodec.h>
#include <commdlg.h>
#include <gdiplus.h>

#include "ui_theme.h"
#include "ui_text.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>


namespace niuma::windows::window {

namespace {
const wchar_t* Ui(const wchar_t* zh, const wchar_t* en) { return niuma::ui::Text(zh, en); }
}  // namespace

// ================= FB10/D22 修行等级窗口（与 mac 对齐）=================
namespace {
constexpr wchar_t kCultClass[] = L"NiuMaMeritCultivation";
constexpr float kCultW = 612.0f;
constexpr float kCultH = 430.0f;
constexpr double kPi = 3.14159265358979323846;

struct CultivationWindowState { HWND window = nullptr; CultivationViewData data; bool hasData = false; };
CultivationWindowState gCult;

std::wstring CultGrouped(std::uint64_t v) {
  std::wstring s = std::to_wstring(v), out;
  int c = 0;
  for (int i = static_cast<int>(s.size()) - 1; i >= 0; --i) {
    out.push_back(s[static_cast<size_t>(i)]);
    if (++c % 3 == 0 && i > 0) out.push_back(L',');
  }
  std::reverse(out.begin(), out.end());
  return out;
}

void CultText(Gdiplus::Graphics& g, const std::wstring& t, Gdiplus::RectF r, float size,
              int style, int align, Gdiplus::Color col) {
  if (t.empty()) return;
  Gdiplus::Font font(L"Microsoft YaHei UI", size, style, Gdiplus::UnitPixel);
  Gdiplus::StringFormat fmt;
  fmt.SetAlignment(static_cast<Gdiplus::StringAlignment>(align));
  fmt.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  fmt.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  Gdiplus::SolidBrush b(col);
  g.DrawString(t.c_str(), -1, &font, r, &fmt, &b);
}

void CultPaint(Gdiplus::Graphics& g, const CultivationViewData& d, float W, float H) {
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
  g.FillRectangle(&white, Gdiplus::RectF(0, 0, W, H));
  const Gdiplus::Color metal(255, 204, 161, 66), metalDark(255, 158, 120, 43),
      ink(255, 29, 29, 31), muted(255, 120, 125, 133), track(255, 230, 230, 230);
  const float cx = W / 2.0f, R = 50.0f, cy = 60.0f;
  { Gdiplus::Pen p(track, 8.0f); g.DrawEllipse(&p, cx - R, cy - R, R * 2, R * 2); }
  const double prog = d.maxLevel ? 1.0 : std::max(0.0, std::min(1.0, d.progress));
  if (prog > 0.0001) {
    Gdiplus::Pen ap(metal, 8.0f); ap.SetStartCap(Gdiplus::LineCapRound); ap.SetEndCap(Gdiplus::LineCapRound);
    g.DrawArc(&ap, cx - R, cy - R, R * 2, R * 2, -90.0f, static_cast<float>(360.0 * prog));
  }
  const float hr = R - 16.0f;
  Gdiplus::PointF pts[6];
  for (int i = 0; i < 6; ++i) {
    const double deg = -90.0 + i * 60.0, rad = deg * kPi / 180.0;
    pts[i] = Gdiplus::PointF(cx + hr * static_cast<float>(cos(rad)), cy + hr * static_cast<float>(sin(rad)));
  }
  { Gdiplus::GraphicsPath hex; hex.AddPolygon(pts, 6); Gdiplus::SolidBrush mf(metal); g.FillPath(&mf, &hex); Gdiplus::Pen md(metalDark, 1.5f); g.DrawPath(&md, &hex); }
  { std::wstring num = std::to_wstring(d.level + 1);
    Gdiplus::Font f(L"Microsoft YaHei UI", hr * 0.92f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::StringFormat fm; fm.SetAlignment(Gdiplus::StringAlignmentCenter); fm.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::SolidBrush b(Gdiplus::Color(242, 255, 255, 255));
    g.DrawString(num.c_str(), -1, &f, Gdiplus::RectF(cx - hr, cy - 20, hr * 2, 40), &fm, &b); }
  float y = cy + R + 8.0f;
  CultText(g, d.title, Gdiplus::RectF(24, y, W - 48, 32), 24, Gdiplus::FontStyleBold, Gdiplus::StringAlignmentCenter, ink); y += 34;
  CultText(g, d.meritText, Gdiplus::RectF(24, y, W - 48, 20), 13, Gdiplus::FontStyleRegular, Gdiplus::StringAlignmentCenter, muted); y += 22;
  CultText(g, d.subtitle, Gdiplus::RectF(24, y, W - 48, 22), 13, Gdiplus::FontStyleRegular, Gdiplus::StringAlignmentCenter, d.maxLevel ? metalDark : muted); y += 30;
  const int n = 6;
  const float rowH = std::min(30.0f, (H - y - 12.0f) / static_cast<float>(n));
  const float leftX = 32.0f, dotR = 7.0f, dotCx = leftX + dotR;
  for (int i = 0; i < n; ++i) {
    const float rowTop = y + rowH * static_cast<float>(i);
    const bool achieved = (i < d.level), current = (i == d.level);
    if (current) { Gdiplus::SolidBrush bg(Gdiplus::Color(36, 204, 161, 66)); const float rx = leftX - 12; g.FillRectangle(&bg, Gdiplus::RectF(rx, rowTop + 2, W - rx * 2, rowH - 4)); }
    const float dotCy = rowTop + rowH / 2.0f;
    if (achieved || current) { Gdiplus::SolidBrush db(metal); g.FillEllipse(&db, dotCx - dotR, dotCy - dotR, dotR * 2, dotR * 2); }
    else { Gdiplus::Pen dp(Gdiplus::Color(255, 199, 199, 199), 1.5f); g.DrawEllipse(&dp, dotCx - dotR, dotCy - dotR, dotR * 2, dotR * 2); }
    if (achieved) {
      Gdiplus::Pen ck(Gdiplus::Color(255, 255, 255, 255), 1.8f); ck.SetStartCap(Gdiplus::LineCapRound); ck.SetEndCap(Gdiplus::LineCapRound);
      g.DrawLine(&ck, dotCx - 3.2f, dotCy + 0.2f, dotCx - 0.8f, dotCy + 2.8f);
      g.DrawLine(&ck, dotCx - 0.8f, dotCy + 2.8f, dotCx + 3.6f, dotCy - 2.6f);
    }
    const Gdiplus::Color tc = current ? ink : (achieved ? ink : muted);
    CultText(g, d.levelTitles[i], Gdiplus::RectF(leftX + dotR * 2 + 12, rowTop + (rowH - 20) / 2, W * 0.5f, 20),
             current ? 15.0f : 14.0f, current ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular, Gdiplus::StringAlignmentNear, tc);
    const std::wstring th = CultGrouped(d.levelThresholds[i]);
    const Gdiplus::Color thc = current ? metalDark : (achieved ? ink : muted);
    CultText(g, th, Gdiplus::RectF(W - leftX - 120, rowTop + (rowH - 18) / 2, 120, 18),
             13.0f, current ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular, Gdiplus::StringAlignmentFar, thc);
  }
}

LRESULT CALLBACK CultivationProc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
  switch (m) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps; HDC hdc = BeginPaint(w, &ps);
      RECT rc; GetClientRect(w, &rc);
      const int cw = rc.right, ch = rc.bottom;
      HDC mem = CreateCompatibleDC(hdc); HBITMAP bmp = CreateCompatibleBitmap(hdc, cw, ch);
      HGDIOBJ old = SelectObject(mem, bmp);
      { Gdiplus::Graphics g(mem); const float scale = cw / kCultW; g.ScaleTransform(scale, scale);
        if (gCult.hasData) CultPaint(g, gCult.data, kCultW, kCultH);
        else { Gdiplus::SolidBrush wh(Gdiplus::Color(255, 255, 255, 255)); g.FillRectangle(&wh, Gdiplus::RectF(0, 0, kCultW, kCultH)); } }
      BitBlt(hdc, 0, 0, cw, ch, mem, 0, 0, SRCCOPY);
      SelectObject(mem, old); DeleteObject(bmp); DeleteDC(mem); EndPaint(w, &ps); return 0;
    }
    case WM_CLOSE: DestroyWindow(w); return 0;
    case WM_DESTROY: gCult.window = nullptr; gCult.hasData = false; return 0;
  }
  return DefWindowProcW(w, m, wp, lp);
}
}  // namespace

void ShowCultivationWindow(HWND owner, const CultivationViewData& data) {
  gCult.data = data; gCult.hasData = true;
  if (gCult.window && IsWindow(gCult.window)) { SetForegroundWindow(gCult.window); InvalidateRect(gCult.window, nullptr, FALSE); return; }
  WNDCLASSEXW wc = {}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = CultivationProc;
  wc.hInstance = GetModuleHandleW(nullptr); wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr; wc.lpszClassName = kCultClass; RegisterClassExW(&wc);
  const UINT dpi = niuma::ui::Dpi(owner); const auto style = WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN;
  RECT d{0, 0, niuma::ui::Dip(static_cast<int>(kCultW), dpi), niuma::ui::Dip(static_cast<int>(kCultH), dpi)};
  AdjustWindowRectEx(&d, style, FALSE, 0);
  RECT work{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int w = std::min<int>(d.right - d.left, work.right - work.left);
  const int h = std::min<int>(d.bottom - d.top, work.bottom - work.top);
  gCult.window = CreateWindowExW(0, kCultClass, Ui(L"修行等级", L"Cultivation Level"), style,
      work.left + (work.right - work.left - w) / 2, work.top + (work.bottom - work.top - h) / 2, w, h,
      owner, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!gCult.window) return;
  niuma::ui::Apply(gCult.window); niuma::ui::WindowChrome(gCult.window);
  ShowWindow(gCult.window, SW_SHOW); SetForegroundWindow(gCult.window); InvalidateRect(gCult.window, nullptr, FALSE);
}

}  // namespace niuma::windows::window