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

  if (g_fail == 0) std::printf("work_encourager_test: OK\n");
  else std::printf("work_encourager_test: %d FAILURES\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
