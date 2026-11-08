// 独立纯算法自测：勋章阈值/周期去重/永久点亮/集齐成就（F3）。
// 编译：SDKROOT=... clang++ -std=c++17 -I ../src medals_test.cpp -o /tmp/md_test
#include "medals.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace niuma::medal;

static int g_fail = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);         \
      ++g_fail;                                                           \
    }                                                                     \
  } while (0)

int main() {
  Thresholds th = BuiltinThresholds();
  CHECK(th.day[0] == 5000 && th.day[1] == 15000 && th.day[2] == 30000);
  CHECK(th.week[2] == 180000 && th.month[0] == 120000);

  // --- HighestTier ---
  CHECK(HighestTier(0, th.day) == -1);
  CHECK(HighestTier(4999, th.day) == -1);
  CHECK(HighestTier(5000, th.day) == 0);
  CHECK(HighestTier(14999, th.day) == 0);
  CHECK(HighestTier(15000, th.day) == 1);
  CHECK(HighestTier(30000, th.day) == 2);
  CHECK(HighestTier(999999, th.day) == 2);

  // --- ApplyMedal: 点亮 + 同周期去重 + 跨周期计次 + 永久点亮 ---
  EarnedMap earned;
  CHECK(ApplyMedal(&earned, "day.bronze", 5000, 5000, "2026-11-08", "2026-11-08"));
  CHECK(earned["day.bronze"].lit);
  CHECK(earned["day.bronze"].count == 1);
  CHECK(earned["day.bronze"].first_earned_day == "2026-11-08");
  // 同一自然周期再次达到：不重复计次
  CHECK(!ApplyMedal(&earned, "day.bronze", 5000, 6000, "2026-11-08", "2026-11-08"));
  CHECK(earned["day.bronze"].count == 1);
  // 新的自然周期达到：计次 +1
  CHECK(ApplyMedal(&earned, "day.bronze", 5000, 5000, "2026-11-09", "2026-11-09"));
  CHECK(earned["day.bronze"].count == 2);
  CHECK(earned["day.bronze"].first_earned_day == "2026-11-08");  // 首次获得日不变
  // 值回落：不撤销、不改变
  CHECK(!ApplyMedal(&earned, "day.bronze", 5000, 100, "2026-11-10", "2026-11-10"));
  CHECK(earned["day.bronze"].lit && earned["day.bronze"].count == 2);
  // 未达阈值：不点亮
  CHECK(!ApplyMedal(&earned, "day.silver", 15000, 12000, "2026-11-08", "2026-11-08"));
  CHECK(earned.find("day.silver") == earned.end());

  // --- EvaluatePeriod: 一次跨多档 ---
  EarnedMap e2;
  CHECK(EvaluatePeriod(&e2, Period::Day, th, "2026-11-08", "2026-11-08", 30000));
  CHECK(e2["day.bronze"].lit && e2["day.silver"].lit && e2["day.gold"].lit);
  CHECK(e2["day.bronze"].count == 1 && e2["day.gold"].count == 1);
  // 再评估同周期不再计次
  CHECK(!EvaluatePeriod(&e2, Period::Day, th, "2026-11-08", "2026-11-08", 30000));

  // --- 周/月周期键与边界 ---
  // 2026-11-08 是周日 -> 本周周一 2026-11-02
  CHECK(WeekPeriodKey(2026, 11, 8) == "2026-11-02");
  CHECK(WeekPeriodKey(2026, 11, 2) == "2026-11-02");
  CHECK(WeekPeriodKey(2026, 11, 9) == "2026-11-09");  // 下一周
  CHECK(MonthPeriodKey(2026, 11) == "2026-11");
  CHECK(MonthPeriodKey(2026, 1) == "2026-01");
  // 跨年周：2027-01-01 周五 -> 周一 2026-12-28
  CHECK(WeekPeriodKey(2027, 1, 1) == "2026-12-28");
  // 月初
  CHECK(WeekPeriodKey(2026, 12, 1) == "2026-11-30");  // 2026-12-01 是周二

  // --- 周/月不同周期分别计次 ---
  EarnedMap e3;
  EvaluatePeriod(&e3, Period::Week, th, WeekPeriodKey(2026, 11, 8), "2026-11-08", 90000);
  CHECK(e3["week.bronze"].lit && e3["week.silver"].lit && !e3["week.gold"].lit);
  // 下一周再达铜：计次 +1
  EvaluatePeriod(&e3, Period::Week, th, WeekPeriodKey(2026, 11, 9), "2026-11-09", 90000);
  CHECK(e3["week.bronze"].count == 2);
  CHECK(e3["week.silver"].count == 2);

  // --- SumRange ---
  std::vector<std::string> keys = {"a", "b", "c"};
  auto lookup = [](const std::string &k) -> std::uint64_t {
    if (k == "a") return 10;
    if (k == "b") return 20;
    return 0;
  };
  CHECK(SumRange(keys, lookup) == 30);

  // --- 集齐成就：9 枚全部点亮才解锁 ---
  EarnedMap e4;
  for (Period p : {Period::Day, Period::Week, Period::Month})
    for (int t = 0; t < 3; ++t)
      EvaluatePeriod(&e4, p, th, "P", "2026-11-08", th.For(p)[2]);
  CHECK(AllMedalsLit(e4));
  CHECK(!e4.count("achievement.all"));
  CHECK(UpdateAchievement(&e4, "2026-11-08"));
  CHECK(e4["achievement.all"].lit && e4["achievement.all"].count == 1);
  CHECK(e4["achievement.all"].first_earned_day == "2026-11-08");
  // 幂等：再次更新不变化
  CHECK(!UpdateAchievement(&e4, "2026-11-09"));

  // 缺一枚则不解锁
  EarnedMap e5 = e4;
  e5.erase("month.gold");
  CHECK(!AllMedalsLit(e5));

  // --- ParseMedalKey ---
  Period p; int t;
  CHECK(ParseMedalKey("month.gold", &p, &t) && p == Period::Month && t == 2);
  CHECK(ParseMedalKey("week.silver", &p, &t) && p == Period::Week && t == 1);
  CHECK(!ParseMedalKey("bad.key", &p, &t));

  if (g_fail == 0) std::printf("medals_test: OK\n");
  else std::printf("medals_test: %d FAILURES\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
