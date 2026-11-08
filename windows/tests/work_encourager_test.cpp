// 独立纯算法自测：上班鼓励器（F2）。
// 编译：clang++ -std=c++17 -I ../src/client/core work_encourager_test.cpp -o /tmp/we_test
// 或直接运行 windows/tests/run_tests.sh。
#include "work_encourager.h"

#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>

using namespace niuma::encourager;

static int g_fail = 0;
static int g_checks = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    ++g_checks;                                                           \
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
  // 非法时段（start>=end / 越界）=> 无效。
  CHECK(!Evaluate(10000, true, Window{1080, 540}, 12 * 3600).valid);
  CHECK(!Evaluate(10000, true, Window{540, 540}, 12 * 3600).valid);
  CHECK((!Window{-1, 60}.Valid()));
  CHECK((!Window{0, 1441}.Valid()));
  CHECK((Window{0, 1440}.Valid()));  // 全天
  CHECK((Window{0, 1440}.TotalSeconds() == 86400));
  CHECK(EarnedMinor(86400, Window{0, 1440}, 43200) == 43200);

  // 边界秒：起点/终点/越界输入。
  CHECK(Evaluate(10000, true, w, -100).before_window);
  CHECK(Evaluate(10000, true, w, -100).earned_minor == 0);
  CHECK(Evaluate(10000, true, w, 90000).after_window);
  CHECK(Evaluate(10000, true, w, 90000).earned_minor == 10000);
  CHECK(Evaluate(10000, true, w, w.EndSecond() - 1).earned_minor == 9999);

  // --- 大额不溢出：日薪 1e15（uint64 量级）---
  Window tiny{0, 1};  // 60 秒窗口
  CHECK(tiny.TotalSeconds() == 60);
  CHECK(EarnedMinor(1000000000000000ULL, tiny, 30) == 500000000000000ULL);
  CHECK(EarnedMinor(1000000000000000ULL, tiny, 60) == 1000000000000000ULL);
  // uint64 上界：结果不超过日薪，且分解算法不溢出。
  const std::uint64_t kMax = std::numeric_limits<std::uint64_t>::max();
  CHECK(EarnedMinor(kMax, tiny, 60) == kMax);
  CHECK(EarnedMinor(kMax, tiny, 30) == kMax / 2);
  CHECK(EarnedMinor(kMax, tiny, 1) == kMax / 60);
  CHECK(EarnedMinor(kMax, w, 13 * 3600 + 1800) <= kMax);

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
  // 语言别名/前缀。
  CHECK(std::string(CurrencyForLanguage("zh-TW").code) == "TWD");
  CHECK(std::string(CurrencyForLanguage("zh-HK").code) == "TWD");
  CHECK(std::string(CurrencyForLanguage("zh-MO").code) == "TWD");
  CHECK(std::string(CurrencyForLanguage("zh-CN").code) == "CNY");
  CHECK(std::string(CurrencyForLanguage("ja-JP").code) == "JPY");
  CHECK(std::string(CurrencyForLanguage("en-US").code) == "USD");
  CHECK(std::string(CurrencyForLanguage("").code) == "CNY");

  // ISO 代码 → 小数位/符号。
  CHECK(ExponentForCode("JPY") == 0);
  CHECK(ExponentForCode("KRW") == 0);
  CHECK(ExponentForCode("VND") == 0);
  CHECK(ExponentForCode("CNY") == 2);
  CHECK(ExponentForCode("USD") == 2);
  CHECK(ExponentForCode("XYZ") == 2);
  CHECK(std::string(SymbolForCode("CNY")) == "CN¥");
  CHECK(std::string(SymbolForCode("TWD")) == "NT$");
  CHECK(std::string(SymbolForCode("JPY")) == "JP¥");
  CHECK(std::string(SymbolForCode("USD")) == "US$");
  CHECK(std::string(SymbolForCode("EUR")) == "€");
  CHECK(std::string(SymbolForCode("GBP")) == "£");
  CHECK(std::string(SymbolForCode("XYZ")) == "");

  // --- 金额格式化 ---
  CHECK(FormatAmountMinor(1234567, 2, "CN¥") == "CN¥12,345.67");
  CHECK(FormatAmountMinor(0, 2, "CN¥") == "CN¥0.00");
  CHECK(FormatAmountMinor(5, 2, "US$") == "US$0.05");
  CHECK(FormatAmountMinor(12346, 0, "JP¥") == "JP¥12,346");
  CHECK(FormatAmountMinor(100000000, 2, "NT$") == "NT$1,000,000.00");
  CHECK(FormatAmountMinor(1, 0, "JP¥") == "JP¥1");
  CHECK(FormatAmountMinor(999, 2, "") == "9.99");
  CHECK(FormatAmountMinor(123456789, 3, "$") == "$123,456.789");
  // exponent 越界钳制：负数按 0，超过 6 按 6。
  CHECK(FormatAmountMinor(123, -1, "$") == "$123");
  CHECK(FormatAmountMinor(1234567890123ULL, 6, "$") == "$1,234,567.890123");

  if (g_fail == 0) std::printf("work_encourager_test: OK (%d checks)\n", g_checks);
  else std::printf("work_encourager_test: %d FAILURES (%d checks)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
