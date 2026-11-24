// 独立纯算法自测：上班鼓励器（F2）。
// 编译：clang++ -std=c++17 -I ../../src work_encourager_test.cpp -o /tmp/we_test
#include "work_encourager.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string>

using namespace niuma::encourager;

static int g_fail = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);         \
      ++g_fail;                                                           \
    }                                                                     \
  } while (0)

int main() {
  // --- 时段 & 每秒累计 ---
  Window w;  // 09:00-18:00 => 32400s
  CHECK(w.Valid());
  CHECK(w.TotalSeconds() == 9 * 3600);
  // 100 元/天 = 10000 minor(分)。半天 = 5000。到止点精确等于日薪。
  CHECK(EarnedMinor(10000, w, 0) == 0);                 // 00:00 时段前
  CHECK(EarnedMinor(10000, w, 9 * 3600 - 1) == 0);      // 08:59:59
  CHECK(EarnedMinor(10000, w, 9 * 3600) == 0);          // 09:00 起点
  CHECK(EarnedMinor(10000, w, 13 * 3600 + 1800) == 5000);  // 13:30 半天
  CHECK(EarnedMinor(10000, w, 18 * 3600) == 10000);     // 18:00 止点=满额
  CHECK(EarnedMinor(10000, w, 23 * 3600) == 10000);     // 止点之后不再涨
  // 每秒增量随秒单调不减。
  std::uint64_t prev = 0;
  for (int s = 0; s <= 86400; s += 7) {
    std::uint64_t v = EarnedMinor(10000, w, s);
    CHECK(v >= prev);
    prev = v;
  }

  // --- Status 状态机 ---
  Status before = Evaluate(10000, true, w, 8 * 3600);
  CHECK(before.valid && before.before_window && !before.in_window);
  CHECK(before.earned_minor == 0 && before.progress == 0.0);

  Status mid = Evaluate(10000, true, w, 13 * 3600 + 1800);
  CHECK(mid.valid && mid.in_window);
  CHECK(mid.earned_minor == 5000);
  CHECK(mid.elapsed_seconds == 4 * 3600 + 1800);
  CHECK(mid.progress > 0.49 && mid.progress < 0.51);

  Status after = Evaluate(10000, true, w, 20 * 3600);
  CHECK(after.valid && after.after_window && !after.in_window);
  CHECK(after.earned_minor == 10000);
  CHECK(after.progress == 1.0);

  // 日薪 0 / 关闭 => 无效。
  CHECK(!Evaluate(0, true, w, 12 * 3600).valid);
  CHECK(!Evaluate(10000, false, w, 12 * 3600).valid);
  // 非法时段（start>=end）=> 无效。
  CHECK(!Evaluate(10000, true, Window{1080, 540}, 12 * 3600).valid);
  CHECK(!Evaluate(10000, true, Window{540, 540}, 12 * 3600).valid);

  // --- 大额不溢出：日薪 1e15（uint64 量级）---
  Window tiny{0, 1};  // 60 秒窗口
  CHECK(tiny.TotalSeconds() == 60);
  CHECK(EarnedMinor(1000000000000000ULL, tiny, 30) == 500000000000000ULL);
  CHECK(EarnedMinor(1000000000000000ULL, tiny, 60) == 1000000000000000ULL);

  // --- 货币映射 ---
  CurrencyInfo cny = CurrencyForLanguage("zh-Hans");
  CHECK(std::string(cny.code) == "CNY" && cny.exponent == 2);
  CurrencyInfo twd = CurrencyForLanguage("zh-Hant");
  CHECK(std::string(twd.code) == "TWD" && twd.exponent == 2);
  CurrencyInfo jpy = CurrencyForLanguage("ja");
  CHECK(std::string(jpy.code) == "JPY" && jpy.exponent == 0);
  CurrencyInfo usd = CurrencyForLanguage("en");
  CHECK(std::string(usd.code) == "USD" && usd.exponent == 2);
  CHECK(std::string(CurrencyForLanguage("xx").code) == "CNY");

  // --- 金额格式化 ---
  CHECK(FormatAmountMinor(1234567, 2, "CN¥") == "CN¥12,345.67");
  CHECK(FormatAmountMinor(0, 2, "CN¥") == "CN¥0.00");
  CHECK(FormatAmountMinor(5, 2, "US$") == "US$0.05");
  CHECK(FormatAmountMinor(12346, 0, "JP¥") == "JP¥12,346");
  CHECK(FormatAmountMinor(100000000, 2, "NT$") == "NT$1,000,000.00");

  // --- FB2（主控修正版）：元 + 5 位小数展示 ---
  // FormatTickAmount：符号 + 千分位整数 + '.' + 5 位小数。
  CHECK(FormatTickAmount(2, "CN¥") == "CN¥0.00002");
  CHECK(FormatTickAmount(3, "NT$") == "NT$0.00003");
  CHECK(FormatTickAmount(4, "US$") == "US$0.00004");
  CHECK(FormatTickAmount(12000000, "CN¥") == "CN¥120.00000");
  CHECK(FormatTickAmount(0, "JP¥") == "JP¥0.00000");
  CHECK(FormatTickAmount(123456789, "JP¥") == "JP¥1,234.56789");
  // D28：展示小数位（日元/韩元 2 位，其余 3 位）与四舍五入格式化。
  CHECK(DisplayDecimalsForCode("JPY") == 2 && DisplayDecimalsForCode("KRW") == 2);
  CHECK(DisplayDecimalsForCode("CNY") == 3 && DisplayDecimalsForCode("EUR") == 3 &&
        DisplayDecimalsForCode("THB") == 3 && DisplayDecimalsForCode("GBP") == 3);
  CHECK(FormatTickAmountDecimals(123456789, "JP¥", 2) == "JP¥1,234.57");
  CHECK(FormatTickAmountDecimals(123456789, "CN¥", 3) == "CN¥1,234.568");
  CHECK(FormatTickAmountDecimals(99999950, "€", 3) == "€1,000.000");   // 999.9995 → 进位
  CHECK(FormatTickAmountDecimals(0, "₩", 2) == "₩0.00");
  CHECK(FormatTickAmountDecimals(12000000, "CN¥", 3) == "CN¥120.000");
  // WageMinorToTick：日薪换算到「元 × 1e5」刻度。
  // CNY 200.00 元 = 20000 分 -> 200.00 元 -> 20000000 tick。
  CHECK(WageMinorToTick(20000, 2) == 20000000ULL);
  // USD 0.80 元 = 80 分 -> 80000 tick。
  CHECK(WageMinorToTick(80, 2) == 80000ULL);
  // JPY 12000 日元 (exponent 0) -> 12000 元 -> 1200000000 tick。
  CHECK(WageMinorToTick(12000, 0) == 1200000000ULL);
  // EarnedTick：到止点等于日薪（tick 刻度）。
  {
    Window w9;  // 09:00-18:00
    CHECK(EarnedTick(WageMinorToTick(20000, 2), w9, 18 * 3600) == 20000000ULL);
    CHECK(EarnedTick(WageMinorToTick(20000, 2), w9, 9 * 3600) == 0ULL);
  }
  // 每秒可见性（关键）：日薪 $0.80 / 9h，5 位小数下末位每秒都在跳。
  // 日薪 0.80 元 = 80000 tick；每秒增量 ≈ 80000/32400 ≈ 2.47 tick，>=1 tick/秒。
  {
    Window w9;
    const std::uint64_t wageTick = WageMinorToTick(80, 2);
    std::uint64_t prev = EarnedTick(wageTick, w9, 10 * 3600);
    for (int s = 1; s <= 60; ++s) {
      std::uint64_t v = EarnedTick(wageTick, w9, 10 * 3600 + s);
      CHECK(v > prev);  // 每秒严格递增（末位每秒变化）
      prev = v;
    }
  }
  // JPY 也每秒递增（5 位小数展示，仅展示不影响结算）。
  {
    Window w9;
    const std::uint64_t wageTick = WageMinorToTick(12000, 0);  // 12000 日元/天
    std::uint64_t prev = EarnedTick(wageTick, w9, 10 * 3600);
    for (int s = 1; s <= 60; ++s) {
      std::uint64_t v = EarnedTick(wageTick, w9, 10 * 3600 + s);
      CHECK(v > prev);
      prev = v;
    }
  }

  // --- FB8：每秒金额按工时精确推算，随上下班时段变化 ---
  {
    Window w8{540, 1020};   // 09:00-17:00 => 28800s（8h）
    Window w9{540, 1080};   // 09:00-18:00 => 32400s（9h）
    CHECK(w8.TotalSeconds() == 8 * 3600);
    CHECK(w9.TotalSeconds() == 9 * 3600);
    // 同一日薪 200.00 元（20000 minor）：时段越长，每秒金额越小。
    const std::uint64_t wageMinor = 20000;
    const std::uint64_t wageTick = WageMinorToTick(wageMinor, 2);  // 20000000 tick
    const std::uint64_t ps8 = PerSecondTick(wageTick, w8);
    const std::uint64_t ps9 = PerSecondTick(wageTick, w9);
    CHECK(ps8 > ps9);                          // 8h 的每秒 > 9h 的每秒
    CHECK(ps8 == 20000000ULL / 28800);         // 694
    CHECK(ps9 == 20000000ULL / 32400);         // 617
    // 恰好等于「日薪 ÷ 总秒数」，不是某个与工时无关的常数。
    CHECK(PerSecondMinor(wageMinor, w8) == 20000ULL / 28800);
    // 小额最小单位会截断为 0，用大额验证「同一日薪、时段不同 → 每秒不同」。
    CHECK(PerSecondMinor(2000000000ULL, w8) != PerSecondMinor(2000000000ULL, w9));
    // 到止点仍精确等于日薪（每秒金额 × 总秒数约等于日薪，截断误差 < 总秒数）。
    CHECK(EarnedTick(wageTick, w8, w8.EndSecond()) == wageTick);
    CHECK(EarnedTick(wageTick, w9, w9.EndSecond()) == wageTick);
    // 非法/零输入 => 0。
    CHECK(PerSecondTick(wageTick, Window{540, 540}) == 0);
    CHECK(PerSecondTick(0, w9) == 0);
    CHECK(PerSecondMinor(0, w9) == 0);
  }

  if (g_fail == 0) std::printf("work_encourager_test: OK\n");
  else std::printf("work_encourager_test: %d FAILURES\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
