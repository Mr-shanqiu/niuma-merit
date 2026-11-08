// 独立纯算法自测：勋章阈值/周期去重/永久点亮/集齐成就（F3）。
// 编译：clang++ -std=c++17 -I ../src/client/core medals_test.cpp -o /tmp/md_test
// 或直接运行 windows/tests/run_tests.sh。
#include "medals.h"

#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace niuma::medal;

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
  Thresholds th = BuiltinThresholds();
  CHECK(th.day[0] == 5000 && th.day[1] == 15000 && th.day[2] == 30000);
  CHECK(th.week[0] == 30000 && th.week[1] == 90000 && th.week[2] == 180000);
  CHECK(th.month[0] == 120000 && th.month[1] == 350000 && th.month[2] == 700000);
  CHECK(th.For(Period::Day) == th.day);
  CHECK(th.For(Period::Week) == th.week);
  CHECK(th.For(Period::Month) == th.month);

  // --- HighestTier ---
  CHECK(HighestTier(0, th.day) == -1);
  CHECK(HighestTier(4999, th.day) == -1);
  CHECK(HighestTier(5000, th.day) == 0);
  CHECK(HighestTier(14999, th.day) == 0);
  CHECK(HighestTier(15000, th.day) == 1);
  CHECK(HighestTier(30000, th.day) == 2);
  CHECK(HighestTier(999999, th.day) == 2);
  const std::uint64_t custom[3] = {1, 2, 3};
  CHECK(HighestTier(0, custom) == -1);
  CHECK(HighestTier(1, custom) == 0);
  CHECK(HighestTier(2, custom) == 1);
  CHECK(HighestTier(3, custom) == 2);

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
  // 空指针安全。
  CHECK(!ApplyMedal(nullptr, "day.bronze", 1, 100, "2026-11-08", "2026-11-08"));

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
  // 闰年 2 月末与跨月周。
  CHECK(WeekPeriodKey(2024, 3, 1) == "2024-02-26");
  CHECK(DayPeriodKey("2026-11-08") == "2026-11-08");

  // --- 周/月不同周期分别计次 ---
  EarnedMap e3;
  EvaluatePeriod(&e3, Period::Week, th, WeekPeriodKey(2026, 11, 8), "2026-11-08", 90000);
  CHECK(e3["week.bronze"].lit && e3["week.silver"].lit && !e3["week.gold"].lit);
  // 下一周再达铜：计次 +1
  EvaluatePeriod(&e3, Period::Week, th, WeekPeriodKey(2026, 11, 9), "2026-11-09", 90000);
  CHECK(e3["week.bronze"].count == 2);
  CHECK(e3["week.silver"].count == 2);
  CHECK(e3["week.bronze"].first_earned_day == "2026-11-08");

  // --- 阈值更新不撤销已获得勋章 ---
  EarnedMap e10;
  EvaluatePeriod(&e10, Period::Day, th, "2026-11-08", "2026-11-08", 5000);
  CHECK(e10["day.bronze"].lit && e10["day.bronze"].count == 1);
  Thresholds raised{{100000, 200000, 300000}, {1, 2, 3}, {1, 2, 3}};
  CHECK(!EvaluatePeriod(&e10, Period::Day, raised, "2026-11-08", "2026-11-08", 5000));
  CHECK(e10["day.bronze"].lit && e10["day.bronze"].count == 1);
  // 同周期即使阈值下调，已点亮的铜牌也不再计次；新达标的银/金正常点亮。
  Thresholds lowered{{1000, 2000, 3000}, {1, 2, 3}, {1, 2, 3}};
  CHECK(EvaluatePeriod(&e10, Period::Day, lowered, "2026-11-08", "2026-11-08", 5000));
  CHECK(e10["day.bronze"].count == 1);
  CHECK(e10["day.silver"].lit && e10["day.gold"].lit);
  CHECK(e10["day.silver"].count == 1 && e10["day.gold"].count == 1);

  // count 饱和于 uint32。
  EarnedMap saturated;
  saturated["day.bronze"].lit = true;
  saturated["day.bronze"].count = UINT32_MAX;
  saturated["day.bronze"].last_period = "old";
  CHECK(ApplyMedal(&saturated, "day.bronze", 1, 1, "new", "2026-11-09"));
  CHECK(saturated["day.bronze"].count == UINT32_MAX);

  // --- SumRange ---
  std::vector<std::string> keys = {"a", "b", "c"};
  auto lookup = [](const std::string &k) -> std::uint64_t {
    if (k == "a") return 10;
    if (k == "b") return 20;
    return 0;
  };
  CHECK(SumRange(keys, lookup) == 30);
  // 饱和：UINT64_MAX + 1 仍为 UINT64_MAX。
  auto big = [](const std::string &) -> std::uint64_t {
    return std::numeric_limits<std::uint64_t>::max();
  };
  CHECK(SumRange(keys, big) == std::numeric_limits<std::uint64_t>::max());

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
  // 空集 / 缺一枚都不解锁。
  CHECK(!AllMedalsLit(EarnedMap{}));
  EarnedMap empty_map;
  CHECK(!UpdateAchievement(&empty_map, "2026-11-08"));
  EarnedMap e5 = e4;
  e5.erase("month.gold");
  CHECK(!AllMedalsLit(e5));

  // --- ParseMedalKey ---
  Period p; int t;
  CHECK(ParseMedalKey("month.gold", &p, &t) && p == Period::Month && t == 2);
  CHECK(ParseMedalKey("week.silver", &p, &t) && p == Period::Week && t == 1);
  CHECK(ParseMedalKey("day.bronze", &p, &t) && p == Period::Day && t == 0);
  CHECK(!ParseMedalKey("bad.key", &p, &t));
  CHECK(!ParseMedalKey("day", &p, &t));
  CHECK(!ParseMedalKey("day.platinum", &p, &t));
  CHECK(!ParseMedalKey("year.gold", &p, &t));
  // 键名生成与解析往返。
  for (Period period : {Period::Day, Period::Week, Period::Month})
    for (int tier = 0; tier < 3; ++tier) {
      Period parsed_period; int parsed_tier = -1;
      CHECK(ParseMedalKey(MedalKey(period, tier), &parsed_period, &parsed_tier));
      CHECK(parsed_period == period && parsed_tier == tier);
    }

  // --- BackfillHistory: 历史静默补授（一次性，CONTRACT_096 §12.1）---
  {
    // 每天 6000：日铜点亮×3；周/月合计不足，不点亮。周键 2026-11-02 起两周。
    EarnedMap e6;
    std::vector<std::string> days = {"2026-10-01", "2026-10-02", "2026-11-08"};
    auto value = [](const std::string &) { return (std::uint64_t)6000; };
    CHECK(BackfillHistory(&e6, th, days, value));
    CHECK(e6["day.bronze"].lit && e6["day.bronze"].count == 3);
    CHECK(e6["day.bronze"].first_earned_day == "2026-10-01");
    CHECK(!e6.count("week.bronze"));
    CHECK(!e6.count("month.bronze"));
    CHECK(!e6.count("achievement.all"));
  }
  {
    // 2026-11-02（周一）..11-08（周日）每天 5000：
    // 日铜×7；周合计 35000 >= 周铜 30000；月合计 35000 < 月铜 120000。
    EarnedMap e7;
    std::vector<std::string> days;
    for (int d = 2; d <= 8; ++d) {
      char buf[16];
      std::snprintf(buf, sizeof(buf), "2026-11-%02d", d);
      days.push_back(buf);
    }
    auto value = [](const std::string &) { return (std::uint64_t)5000; };
    CHECK(BackfillHistory(&e7, th, days, value));
    CHECK(e7["day.bronze"].count == 7);
    CHECK(e7["week.bronze"].lit && e7["week.bronze"].count == 1);
    CHECK(e7["week.bronze"].first_earned_day == "2026-11-02");
    CHECK(!e7.count("month.bronze"));
    // 空/全非法键：无变化
    EarnedMap e8 = e7;
    std::vector<std::string> bad = {"not-a-date", ""};
    CHECK(!BackfillHistory(&e8, th, bad, value));
    CHECK(e8["day.bronze"].count == 7);
    CHECK(!BackfillHistory(nullptr, th, days, value));
  }
  {
    // 集齐成就补授：日/周/月全部达标（月合计 800000 >= 700000；两日分属不同周，
    // 各周 400000 >= 180000）-> achievement.all 点亮，首次日 = 最后一天。
    EarnedMap e9;
    std::vector<std::string> days = {"2026-11-01", "2026-11-08"};
    auto value = [](const std::string &) { return (std::uint64_t)400000; };
    CHECK(BackfillHistory(&e9, th, days, value));
    CHECK(AllMedalsLit(e9));
    CHECK(e9["achievement.all"].lit && e9["achievement.all"].count == 1);
    CHECK(e9["achievement.all"].first_earned_day == "2026-11-08");
  }

  if (g_fail == 0) std::printf("medals_test: OK (%d checks)\n", g_checks);
  else std::printf("medals_test: %d FAILURES (%d checks)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
