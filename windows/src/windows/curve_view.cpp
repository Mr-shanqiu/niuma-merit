// F4 · 牛马曲线窗口实现（GDI+ 绘制 + WIC PNG 导出）。
#include "curve_view.h"

// GDI+ 依赖 objidl.h（IStream）与 propidl.h（PROPID），必须先于 gdiplus.h。
#include <objidl.h>
#include <propidl.h>
#include <wincodec.h>
#include <commdlg.h>
#include <gdiplus.h>

#include "ui_theme.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace niuma::windows::window {

namespace {

constexpr wchar_t kCurveClass[] = L"NiuMaMeritCurve";
constexpr int kCurveDayButton = 4301;
constexpr int kCurveWeekButton = 4302;
constexpr int kCurveMonthButton = 4303;
constexpr int kCurveExportButton = 4304;
constexpr float kCurveWidth = 760.0f;
constexpr float kCurveHeight = 470.0f;

struct CurveWindowState {
  HWND window = nullptr;
  CurveViewData data;
  bool hasData = false;
};

CurveWindowState gCurve;

const wchar_t* CurveFontFamily() {
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
    Gdiplus::Font font(CurveFontFamily(), fitted,
                       bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                       Gdiplus::UnitPixel);
    Gdiplus::RectF measured;
    graphics.MeasureString(text.c_str(), -1, &font, Gdiplus::PointF(0, 0), &measured);
    if (measured.Width <= rect.Width) break;
    fitted -= 1;
  }
  Gdiplus::Font font(CurveFontFamily(), fitted,
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

// 通用绘制：width/height 为设计尺寸，scale 已在调用方设置。draw 内部对齐到设计坐标系。
void PaintCurve(Gdiplus::Graphics& graphics, const CurveViewData& data, bool chinese) {
  const float W = kCurveWidth, H = kCurveHeight;
  graphics.Clear(Gdiplus::Color::White);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

  const Gdiplus::Color ink(255, 29, 29, 31), muted(255, 110, 110, 115),
      accent(255, 240, 139, 35), blue(255, 0, 112, 245),
      rule(255, 233, 233, 236), uncollected(255, 224, 224, 228);

  const wchar_t* zhDay = L"牛马曲线 · 今日（%s）";
  const wchar_t* enDay = L"Merit Curve · Today (%s)";
  const wchar_t* zhWeek = L"牛马曲线 · 本周（周一–周日）";
  const wchar_t* enWeek = L"Merit Curve · This Week (Mon–Sun)";
  std::wstring title;
  wchar_t buffer[128] = {};
  if (data.mode == CurveViewMode::Day) {
    swprintf_s(buffer, std::size(buffer), chinese ? zhDay : enDay, data.todayKey.c_str());
    title = buffer;
  } else if (data.mode == CurveViewMode::Week) {
    title = chinese ? zhWeek : enWeek;
  } else {
    swprintf_s(buffer, std::size(buffer),
               chinese ? L"牛马曲线 · %d 年 %d 月" : L"Merit Curve · %d / %d",
               data.year, data.month);
    title = buffer;
  }
  DrawText(graphics, title, Gdiplus::RectF(28, 20, W - 56, 32), 22, ink, true);

  const float left = 64, right = 28, top = 78, bottom = 60;
  const Gdiplus::RectF plot(left, top, W - left - right, H - top - bottom);
  Gdiplus::Pen rulePen(rule, 1);
  graphics.DrawLine(&rulePen, plot.X, plot.GetBottom(), plot.GetRight(), plot.GetBottom());

  if (data.mode == CurveViewMode::Day) {
    // 今日总计（旧日总数，权威来源）。
    DrawText(graphics, chinese ? L"今日总计" : L"Today's total",
             Gdiplus::RectF(28, 48, 120, 18), 11, muted, false);
    DrawText(graphics, Number(data.todayTotal),
             Gdiplus::RectF(W - 260, 44, 232, 28), 22, ink, true,
             Gdiplus::StringAlignmentFar);
    if (data.dayBuckets.size() != 96 || data.dayCoverage.size() != 96) {
      DrawText(graphics,
               chinese ? L"今日暂无 0.9.6 采集数据（历史旧日按「未采集」处理）"
                       : L"No 0.9.6 samples yet today (older days show as not collected).",
               Gdiplus::RectF(plot.X, plot.Y + plot.Height / 2 - 10, plot.Width, 22),
               13, muted, false);
      return;
    }
    std::uint64_t maxValue = 0;
    for (int i = 0; i < 96; ++i)
      if (data.dayCoverage[i]) maxValue = std::max(maxValue, data.dayBuckets[i]);
    if (maxValue == 0) maxValue = 1;
    const float step = plot.Width / 96.0f;
    for (int i = 0; i < 96; ++i) {
      const float cellX = plot.X + i * step;
      const float cellW = std::max(1.0f, step - 1.0f);
      if (!data.dayCoverage[i]) {
        // 未采集：底部一条浅灰底纹，不画 0。
        Gdiplus::SolidBrush shade(uncollected);
        graphics.FillRectangle(&shade, Gdiplus::RectF(cellX, plot.GetBottom() - 3, cellW, 3));
        continue;
      }
      const std::uint64_t value = data.dayBuckets[i];
      float h = plot.Height * static_cast<float>(value) / static_cast<float>(maxValue);
      if (value > 0 && h < 2) h = 2;
      Gdiplus::SolidBrush bar((i >= 36 && i < 54) ? blue : accent);
      graphics.FillRectangle(&bar, Gdiplus::RectF(cellX, plot.GetBottom() - h, cellW, h));
    }
    for (int hour = 0; hour <= 24; hour += 6) {
      const float x = plot.X + plot.Width * hour / 24.0f;
      wchar_t label[8] = {};
      swprintf_s(label, std::size(label), L"%02d:00", hour);
      DrawText(graphics, label, Gdiplus::RectF(x - 26, plot.GetBottom() + 8, 52, 16), 10,
               muted, false, Gdiplus::StringAlignmentCenter);
    }
    DrawText(graphics,
             (chinese ? L"峰值/桶 " : L"Peak/bucket ") + Number(maxValue),
             Gdiplus::RectF(plot.X, plot.Y - 18, 240, 16), 11, muted, false);
    // 图例：未采集。
    {
      Gdiplus::SolidBrush shade(uncollected);
      graphics.FillRectangle(&shade, Gdiplus::RectF(plot.GetRight() - 150, plot.Y - 16, 14, 6));
      DrawText(graphics, chinese ? L"未采集" : L"Not collected",
               Gdiplus::RectF(plot.GetRight() - 130, plot.Y - 21, 120, 16), 11, muted);
    }
    if (data.dayPartial) {
      DrawText(graphics, chinese ? L"部分采集（升级当天）" : L"Partial capture (upgrade day)",
               Gdiplus::RectF(plot.X, plot.GetBottom() + 26, 300, 16), 11, muted);
    }
    return;
  }

  // 周 / 月：读取每日总。
  std::uint64_t maxValue = 0;
  for (std::uint64_t v : data.rangeValues) maxValue = std::max(maxValue, v);
  if (maxValue == 0) maxValue = 1;
  const size_t count = data.rangeValues.size();
  if (count == 0) return;
  const float slot = plot.Width / static_cast<float>(count);
  const float barWidth = std::max(4.0f, slot * 0.62f);
  const float labelSize = count > 12 ? 8.0f : 11.0f;
  for (size_t i = 0; i < count; ++i) {
    const float cx = plot.X + slot * (static_cast<float>(i) + 0.5f);
    float h = plot.Height * static_cast<float>(data.rangeValues[i]) /
              static_cast<float>(maxValue);
    if (data.rangeValues[i] > 0 && h < 2) h = 2;
    Gdiplus::SolidBrush bar(i == 0 ? blue : accent);
    graphics.FillRectangle(&bar, Gdiplus::RectF(cx - barWidth / 2, plot.GetBottom() - h, barWidth, h));
    const std::wstring label =
        i < data.rangeLabels.size() ? data.rangeLabels[i] : std::to_wstring(i + 1);
    const float lw = count > 20 ? 20.0f : 40.0f;
    DrawText(graphics, label,
             Gdiplus::RectF(cx - lw / 2, plot.GetBottom() + 6, lw, 16), labelSize, muted,
             false, Gdiplus::StringAlignmentCenter);
    if (count <= 12) {
      DrawText(graphics, Number(data.rangeValues[i]),
               Gdiplus::RectF(cx - 40, plot.GetBottom() - h - 18, 80, 14), 10, ink, false,
               Gdiplus::StringAlignmentCenter);
    }
  }
  DrawText(graphics, (chinese ? L"峰值 " : L"Peak ") + Number(maxValue),
           Gdiplus::RectF(plot.X, plot.Y - 18, 240, 16), 11, muted, false);
}

float CurveScale(HWND window) {
  RECT client{};
  GetClientRect(window, &client);
  return std::max(0.1f, std::min(client.right / kCurveWidth, client.bottom / kCurveHeight));
}

void LayoutCurve(HWND window) {
  const float scale = CurveScale(window);
  const auto move = [&](int id, int x, int y, int w, int h) {
    MoveWindow(GetDlgItem(window, id), static_cast<int>(x * scale),
               static_cast<int>(y * scale), static_cast<int>(w * scale),
               static_cast<int>(h * scale), TRUE);
  };
  move(kCurveDayButton, 24, 436, 64, 28);
  move(kCurveWeekButton, 92, 436, 64, 28);
  move(kCurveMonthButton, 160, 436, 64, 28);
  move(kCurveExportButton, 552, 434, 184, 30);
}

void PaintCurveWindow(HWND window) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  RECT client{};
  GetClientRect(window, &client);
  const bool chinese =
      PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
  if (dc && client.right > 0 && client.bottom > 0) {
    niuma::ui::PaintBuffered(dc, client, [&](HDC memory) {
      Gdiplus::Graphics graphics(memory);
      graphics.ScaleTransform(CurveScale(window), CurveScale(window));
      PaintCurve(graphics, gCurve.data, chinese);
      graphics.Flush(Gdiplus::FlushIntentionSync);
    });
  }
  EndPaint(window, &paint);
}

LRESULT CALLBACK CurveWindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      PaintCurveWindow(window);
      return 0;
    case WM_PRINTCLIENT: {
      Gdiplus::Graphics graphics(reinterpret_cast<HDC>(wParam));
      graphics.ScaleTransform(CurveScale(window), CurveScale(window));
      const bool chinese = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
      PaintCurve(graphics, gCurve.data, chinese);
      graphics.Flush(Gdiplus::FlushIntentionSync);
      return 0;
    }
    case WM_SIZE:
      LayoutCurve(window);
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
      if (id == kCurveDayButton || id == kCurveWeekButton || id == kCurveMonthButton) {
        gCurve.data.mode = id == kCurveDayButton ? CurveViewMode::Day
                          : id == kCurveWeekButton ? CurveViewMode::Week
                                                   : CurveViewMode::Month;
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      }
      if (id == kCurveExportButton) {
        // 导出由 app 层（持有数据与分享模型）处理：向 owner 投递自定义消息。
        HWND owner = GetWindow(window, GW_OWNER);
        if (owner) PostMessageW(owner, kCurveExportMessage, 0, 0);
        return 0;
      }
      return 0;
    }
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      gCurve.window = nullptr;
      return 0;
    default:
      break;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace

bool CurveWindowOpen() { return gCurve.window != nullptr && IsWindow(gCurve.window); }

CurveViewMode CurrentCurveMode() { return gCurve.data.mode; }

void RefreshCurveWindow(const CurveViewData& data) {
  gCurve.data = data;
  gCurve.hasData = true;
  if (CurveWindowOpen()) InvalidateRect(gCurve.window, nullptr, FALSE);
}

void CloseCurveWindow() {
  if (CurveWindowOpen()) DestroyWindow(gCurve.window);
}

void ShowCurveWindow(HWND owner, const CurveViewData& data) {
  gCurve.data = data;
  gCurve.hasData = true;
  if (CurveWindowOpen()) {
    SetForegroundWindow(gCurve.window);
    InvalidateRect(gCurve.window, nullptr, FALSE);
    return;
  }
  // 懒注册窗口类（幂等；重复注册返回 0 无害）。
  WNDCLASSEXW curveClass = {};
  curveClass.cbSize = sizeof(curveClass);
  curveClass.lpfnWndProc = CurveWindowProcedure;
  curveClass.hInstance = GetModuleHandleW(nullptr);
  curveClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  curveClass.hbrBackground = nullptr;
  curveClass.lpszClassName = kCurveClass;
  RegisterClassExW(&curveClass);
  const UINT dpi = niuma::ui::Dpi(owner);
  const auto style = WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN | WS_THICKFRAME;
  RECT desired{0, 0, niuma::ui::Dip(static_cast<int>(kCurveWidth), dpi),
               niuma::ui::Dip(static_cast<int>(kCurveHeight), dpi)};
  AdjustWindowRectEx(&desired, style, FALSE, 0);
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int width = std::min(desired.right - desired.left, work.right - work.left);
  const int height = std::min(desired.bottom - desired.top, work.bottom - work.top);
  const bool chinese = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
  gCurve.window = CreateWindowExW(
      0, kCurveClass, chinese ? L"牛马曲线" : L"Merit Curve", style,
      work.left + (work.right - work.left - width) / 2,
      work.top + (work.bottom - work.top - height) / 2, width, height, owner, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!gCurve.window) return;
  const auto createButton = [&](int id, const wchar_t* text) {
    CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                    0, 0, 1, 1, gCurve.window,
                    reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                    GetModuleHandleW(nullptr), nullptr);
  };
  createButton(kCurveDayButton, chinese ? L"日" : L"Day");
  createButton(kCurveWeekButton, chinese ? L"周" : L"Week");
  createButton(kCurveMonthButton, chinese ? L"月" : L"Month");
  createButton(kCurveExportButton, chinese ? L"导出分享图…" : L"Export Share Image…");
  niuma::ui::Apply(gCurve.window);
  LayoutCurve(gCurve.window);
  niuma::ui::WindowChrome(gCurve.window);
  ShowWindow(gCurve.window, SW_SHOW);
  SetForegroundWindow(gCurve.window);
  SetFocus(gCurve.window);
  InvalidateRect(gCurve.window, nullptr, FALSE);
}

// ---- PNG 导出（WIC 编码，无文本块/EXIF）----

namespace {

bool SavePngToFile(const std::wstring& path, Gdiplus::Bitmap& bitmap) {
  CLSID pngEncoder{};
  UINT count = 0, size = 0;
  if (Gdiplus::GetImageEncodersSize(&count, &size) != Gdiplus::Ok || size == 0) return false;
  std::vector<BYTE> buffer(size);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  if (Gdiplus::GetImageEncoders(count, size, encoders) != Gdiplus::Ok) return false;
  bool found = false;
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(encoders[i].MimeType, L"image/png") == 0) {
      pngEncoder = encoders[i].Clsid;
      found = true;
      break;
    }
  }
  if (!found) return false;
  return bitmap.Save(path.c_str(), &pngEncoder, nullptr) == Gdiplus::Ok;
}

}  // namespace

bool ExportCurvePng(HWND owner, const CurveViewData& data, const std::wstring& suggestedName,
                    const std::wstring& titleZh, const std::wstring& titleEn, bool chinese,
                    std::wstring* errorOut) {
  // 先渲染到内存位图（1000x1250 分享卡比例，便于社交分享）。
  const int imageWidth = 1000, imageHeight = 1000;
  Gdiplus::Bitmap bitmap(imageWidth, imageHeight, PixelFormat32bppARGB);
  {
    Gdiplus::Graphics graphics(&bitmap);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    Gdiplus::SolidBrush background(Gdiplus::Color(255, 250, 248, 244));
    graphics.FillRectangle(&background, Gdiplus::RectF(0, 0, static_cast<Gdiplus::REAL>(imageWidth), static_cast<Gdiplus::REAL>(imageHeight)));
    // 页眉
    const Gdiplus::Color ink(255, 29, 29, 31), muted(255, 110, 110, 115);
    DrawText(graphics, chinese ? titleZh : titleEn,
             Gdiplus::RectF(48, 40, imageWidth - 96, 44), 30, ink, true);
    std::wstring subtitle;
    if (data.mode == CurveViewMode::Day)
      subtitle = chinese ? (L"今日 96 桶 · " + data.todayKey)
                         : (L"Today, 96 buckets · " + data.todayKey);
    else if (data.mode == CurveViewMode::Week)
      subtitle = chinese ? L"本周每日功德（周一–周日）" : L"Daily merit this week (Mon–Sun)";
    else {
      wchar_t buffer[64] = {};
      swprintf_s(buffer, std::size(buffer), chinese ? L"%d 年 %d 月每日功德" : L"Daily merit %d / %d",
                 data.year, data.month);
      subtitle = buffer;
    }
    DrawText(graphics, subtitle, Gdiplus::RectF(48, 90, imageWidth - 96, 26), 16, muted, false);
    // 主体绘图区：把曲线以设计坐标平移缩放进卡面。
    Gdiplus::GraphicsState state = graphics.Save();
    const float scale = std::min((imageWidth - 96.0f) / kCurveWidth,
                                 (imageHeight - 260.0f) / kCurveHeight);
    graphics.TranslateTransform(48.0f, 150.0f);
    graphics.ScaleTransform(scale, scale);
    PaintCurve(graphics, data, chinese);
    graphics.Restore(state);
    // 页脚水印（仅产品名/版本，无路径/账号）。
    DrawText(graphics, chinese ? L"牛马电子功德" : L"NiuMa Merit",
             Gdiplus::RectF(48, imageHeight - 70, 400, 30), 16, muted, false);
    DrawText(graphics, L"niuma-merit 0.9.6",
             Gdiplus::RectF(imageWidth - 348, imageHeight - 70, 300, 30), 14, muted, false,
             Gdiplus::StringAlignmentFar);
    graphics.Flush(Gdiplus::FlushIntentionSync);
  }

  // 保存对话框（comdlg32）。
  wchar_t fileBuffer[MAX_PATH] = {};
  if (!suggestedName.empty()) wcsncpy_s(fileBuffer, suggestedName.c_str(), _TRUNCATE);
  OPENFILENAMEW ofn{};
  ofn.lStructSize = sizeof(ofn);
  ofn.hwndOwner = owner;
  ofn.lpstrFilter = L"PNG (*.png)\0*.png\0";
  ofn.lpstrFile = fileBuffer;
  ofn.nMaxFile = MAX_PATH;
  ofn.lpstrDefExt = L"png";
  ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
  if (!GetSaveFileNameW(&ofn)) return false;  // 用户取消。
  if (!SavePngToFile(fileBuffer, bitmap)) {
    if (errorOut) *errorOut = L"PNG encode failed";
    return false;
  }
  return true;
}

}  // namespace niuma::windows::window
