#pragma once

// F2 · 上班鼓励器 —— 纯算法层（仅使用标准 C++，可独立单元测试）。
//
// Windows 移植自 macos/src/work_encourager.h，规则与函数签名保持一致：
//   - 每秒增量 = 日薪 ÷ 上班总秒数；按本地墙钟累加。
//   - 时段外暂停：起之前为 0，止之后为全天已满（等于日薪）。
//   - 每日零点归零；每天生效（含周末）；跨午夜不支持（要求 start < end）。
//   - 日薪为 0 关闭。
//   - 金额一律以最小货币单位整数（uint64）存储与计算，不用浮点累计。
//
// 该层不做任何 I/O，也不依赖 Win32，便于与 UI 分离测试。
//
// 与 macOS 的唯一实现差异：EarnedMinor 用「商/余数分解」完成精确 64 位
// 乘除，避免 MSVC 不支持 unsigned __int128。数学上与 __int128 版本逐位
// 相同（见 EarnedMinor 注释）。

#include <algorithm>
#include <cstddef>
#include <cstdint>
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

// 精确计算 floor(daily_wage_minor * elapsed / total)，无 128 位依赖。
//
// 令 wage = q*total + r（0 <= r < total），elapsed 已钳制到 [0, total]：
//   floor(wage*elapsed/total)
//     = q*elapsed + floor(r*elapsed/total)
// 其中 q*elapsed <= q*total <= wage，r*elapsed < total^2 <= 86400^2 < 2^33，
// 因此两个中间量都不会溢出 uint64，结果也与 unsigned __int128 版本一致。
inline std::uint64_t EarnedMinor(std::uint64_t daily_wage_minor, const Window& window,
                                 int second_of_day) {
  if (daily_wage_minor == 0 || !window.Valid()) return 0;
  const int total_seconds = window.TotalSeconds();
  if (total_seconds <= 0) return 0;
  const int elapsed = std::clamp(second_of_day - window.StartSecond(), 0, total_seconds);
  const std::uint64_t total = static_cast<std::uint64_t>(total_seconds);
  const std::uint64_t elapsed_u = static_cast<std::uint64_t>(elapsed);
  const std::uint64_t whole = (daily_wage_minor / total) * elapsed_u;
  const std::uint64_t remainder = daily_wage_minor % total;
  return whole + (remainder * elapsed_u) / total;
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

// 最小单位整数 → 展示字符串。分组千位，按 exponent 插入小数点
// （half-up 已由整数存储保证，展示层不再做浮点舍入）。
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

}  // namespace encourager
}  // namespace niuma
