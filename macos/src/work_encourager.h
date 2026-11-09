#pragma once

// F2 · 上班鼓励器 —— 纯算法层（仅使用标准 C++，可独立单元测试）。
//
// 规则（CONTRACT_096 §3 / §9、FEATURE_FREEZE §五）：
//   - 每秒增量 = 日薪 ÷ 上班总秒数；按本地墙钟累加。
//   - 时段外暂停：起之前为 0，止之后为全天已满（等于日薪）。
//   - 每日零点归零；每天生效（含周末）；跨午夜不支持（要求 start < end）。
//   - 日薪为 0 关闭。
//   - 金额一律以最小货币单位整数（uint64）存储与计算，不用浮点累计。
//
// 该层不做任何 I/O，也不依赖 AppKit，便于与 UI 分离测试。

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>

namespace niuma {
namespace encourager {

// 上班时段：分钟数，0 <= start < end <= 1440。
struct Window {
  int start_minute = 540;   // 09:00
  int end_minute = 1080;    // 18:00

  bool Valid() const {
    return start_minute >= 0 && end_minute <= 1440 &&
           start_minute < end_minute;
  }
  int StartSecond() const { return start_minute * 60; }
  int EndSecond() const { return end_minute * 60; }
  int TotalSeconds() const {
    return Valid() ? (end_minute - start_minute) * 60 : 0;
  }
};

// 一次求值的结果。earned_minor 为“今日已赚”的最小货币单位整数。
struct Status {
  bool valid = false;        // 设置合法且启用（日薪>0、时段合法）
  bool in_window = false;    // 当前是否处于上班时段内
  bool before_window = false;
  bool after_window = false;
  int second_of_day = 0;     // 传入的本地当日秒
  int elapsed_seconds = 0;   // 时段内已过去的秒（0..window）
  int total_seconds = 0;     // 时段总秒
  std::uint64_t daily_wage_minor = 0;
  std::uint64_t earned_minor = 0;
  // progress 0..1（用于进度条），elapsed/total；无有效时段为 0。
  double progress = 0.0;
};

// 用 128 位中间量做 wage*elapsed/window，避免 uint64 溢出，且到止点精确等于日薪。
inline std::uint64_t EarnedMinor(std::uint64_t daily_wage_minor, const Window& window,
                                 int second_of_day) {
  if (daily_wage_minor == 0 || !window.Valid()) return 0;
  const int total = window.TotalSeconds();
  if (total <= 0) return 0;
  const int elapsed = std::clamp(second_of_day - window.StartSecond(), 0, total);
  const unsigned __int128 scaled =
      static_cast<unsigned __int128>(daily_wage_minor) *
      static_cast<unsigned __int128>(elapsed);
  return static_cast<std::uint64_t>(scaled / static_cast<unsigned __int128>(total));
}

// 计算给定本地当日秒（0..86399，允许越界用于测试）的鼓励器状态。
inline Status Evaluate(std::uint64_t daily_wage_minor, bool enabled, const Window& window,
                       int second_of_day) {
  Status result;
  result.second_of_day = second_of_day;
  result.daily_wage_minor = daily_wage_minor;
  result.total_seconds = window.TotalSeconds();
  if (!enabled || daily_wage_minor == 0 || !window.Valid()) return result;
  result.valid = true;
  const int start = window.StartSecond();
  const int end = window.EndSecond();
  result.before_window = second_of_day < start;
  result.after_window = second_of_day >= end;
  result.in_window = !result.before_window && !result.after_window;
  result.elapsed_seconds = std::clamp(second_of_day - start, 0, result.total_seconds);
  result.earned_minor = EarnedMinor(daily_wage_minor, window, second_of_day);
  result.progress = result.total_seconds > 0
      ? static_cast<double>(result.elapsed_seconds) / result.total_seconds
      : 0.0;
  return result;
}

// ---- 货币映射（CONTRACT_096 §9，跟随语言、可覆盖） ----

struct CurrencyInfo {
  const char* code;    // ISO 4217
  const char* symbol;  // 展示符号（UTF-8）
  int exponent;        // 小数位
};

// 语言 → 默认货币。未知语言回落 zh-Hans(CNY)。
inline CurrencyInfo CurrencyForLanguage(const std::string& language) {
  if (language == "zh-Hant" || language == "zh-TW" || language == "zh-HK" ||
      language == "zh-MO")
    return CurrencyInfo{"TWD", "NT$", 2};
  if (language == "ja" || language.compare(0, 2, "ja") == 0)
    return CurrencyInfo{"JPY", "JP¥", 0};
  if (language == "en" || language.compare(0, 2, "en") == 0)
    return CurrencyInfo{"USD", "US$", 2};
  return CurrencyInfo{"CNY", "CN¥", 2};
}

// 已知 ISO 4217 代码 → 小数位；未知按 2 位处理。
inline int ExponentForCode(const std::string& code) {
  if (code == "JPY" || code == "KRW" || code == "VND") return 0;
  return 2;
}

inline const char* SymbolForCode(const std::string& code) {
  if (code == "CNY") return "CN¥";
  if (code == "TWD") return "NT$";
  if (code == "JPY") return "JP¥";
  if (code == "USD") return "US$";
  if (code == "EUR") return "€";
  if (code == "GBP") return "£";
  return "";
}

// 最小单位整数 → 展示字符串。分组千位，按 exponent 插入小数点（half-up 已由整数存储保证）。
inline std::string FormatAmountMinor(std::uint64_t amount_minor, int exponent,
                                     const std::string& symbol) {
  if (exponent < 0) exponent = 0;
  if (exponent > 6) exponent = 6;
  std::uint64_t divisor = 1;
  for (int i = 0; i < exponent; ++i) divisor *= 10;
  const std::uint64_t whole = amount_minor / divisor;
  const std::uint64_t frac = amount_minor % divisor;

  std::string digits = std::to_string(whole);
  std::string grouped;
  int count = 0;
  for (int i = static_cast<int>(digits.size()) - 1; i >= 0; --i) {
    grouped.push_back(digits[static_cast<std::size_t>(i)]);
    if (++count % 3 == 0 && i > 0) grouped.push_back(',');
  }
  std::reverse(grouped.begin(), grouped.end());

  std::string out = symbol;
  out += grouped;
  if (exponent > 0) {
    std::string fracStr = std::to_string(frac);
    while (static_cast<int>(fracStr.size()) < exponent) fracStr.insert(fracStr.begin(), '0');
    out.push_back('.');
    out += fracStr;
  }
  return out;
}

// FB2 · 鼓励器「数字跳动」显示（主控 2026-11-10 修正版）。
//
// 要求：金额一律以「元」为单位、小数点后保留 **5 位小数**（如 ¥0.00002、
// NT$0.00003、$0.00004），币种符号照旧（CN¥/NT$/JP¥/US$），JPY 也保留 5 位小数
// （仅为展示效果，不影响结算/契约的最小单位与 exponent）。目的：日薪 $0.80 时
// 每秒增量约 0.0000247 元，5 位小数下末位每秒都在跳，形成「数字不停变动」。
//
// 实现：把「今日已赚」换算到 1e-5 元（TickUnitsPerYuan=100000）的整数刻度上，
// 用 128 位中间量求值，再按 5 位小数格式化。存储/契约最小单位与 exponent 不变；
// 分享卡仍写契约规定的 amount_display（见 share_card / 调用方）。
constexpr std::uint64_t kTickUnitsPerYuan = 100000ULL;  // 5 位小数

// 把「日薪（最小货币单位）」换算成「元 × 1e5」整数刻度。
// amount_minor / 10^exponent = 元；再 × 1e5 得 tick。
// exponent<=5 时精确（先乘后除）；exponent>5 时先除后乘（极少见，按截断）。
inline std::uint64_t WageMinorToTick(std::uint64_t daily_wage_minor, int exponent) {
  if (exponent < 0) exponent = 0;
  if (exponent > 6) exponent = 6;
  std::uint64_t pow10 = 1;
  for (int i = 0; i < exponent; ++i) pow10 *= 10;
  if (exponent <= 5) {
    return daily_wage_minor * kTickUnitsPerYuan / pow10;
  }
  return (daily_wage_minor / pow10) * kTickUnitsPerYuan;
}

// 在「元 × 1e5」刻度上求「今日已赚」，语义与 EarnedMinor 一致（到止点等于日薪）。
inline std::uint64_t EarnedTick(std::uint64_t daily_wage_tick, const Window& window,
                                int second_of_day) {
  if (daily_wage_tick == 0 || !window.Valid()) return 0;
  const int total = window.TotalSeconds();
  if (total <= 0) return 0;
  const int elapsed = std::clamp(second_of_day - window.StartSecond(), 0, total);
  const unsigned __int128 scaled =
      static_cast<unsigned __int128>(daily_wage_tick) *
      static_cast<unsigned __int128>(elapsed);
  return static_cast<std::uint64_t>(scaled / static_cast<unsigned __int128>(total));
}

// 把「元 × 1e5」整数刻度格式化为「符号 + 千分位整数 + '.' + 5 位小数」。
// 例：2 -> "CN¥0.00002"；3 -> "NT$0.00003"；4 -> "US$0.00004"；12000000 -> "CN¥120.00000"。
inline std::string FormatTickAmount(std::uint64_t tick, const std::string& symbol) {
  const std::uint64_t whole = tick / kTickUnitsPerYuan;
  const std::uint64_t frac = tick % kTickUnitsPerYuan;
  std::string digits = std::to_string(whole);
  std::string grouped;
  int count = 0;
  for (int i = static_cast<int>(digits.size()) - 1; i >= 0; --i) {
    grouped.push_back(digits[static_cast<std::size_t>(i)]);
    if (++count % 3 == 0 && i > 0) grouped.push_back(',');
  }
  std::reverse(grouped.begin(), grouped.end());
  std::string fracStr = std::to_string(frac);
  while (fracStr.size() < 5) fracStr.insert(fracStr.begin(), '0');
  std::string out = symbol;
  out += grouped;
  out.push_back('.');
  out += fracStr;
  return out;
}

}  // namespace encourager
}  // namespace niuma
