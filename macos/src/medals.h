#pragma once

// F3 · 勋章 —— 纯算法层（仅标准 C++，可独立单元测试）。
//
// 契约（CONTRACT_096 §3 / §4.2 / §7.4、FEATURE_FREEZE §六）：
//   - 周期：日 / 周（周一–周日）/ 月（自然月），各 铜/银/金，共 9 枚 + 集齐成就。
//   - 阈值占位：日 5k/15k/30k；周 30k/90k/180k；月 120k/350k/700k。
//   - 归集自「每日累计」（dailyTotals，权威来源），正确处理自然周/月边界与时区
//     （调用方用本地日键；本层只做日期算术）。
//   - 首次达成永久点亮并记录获得次数；同一档位每个自然周期最多计 1 次
//     （用 last_period 去重，允许跨重启）。
//   - 阈值更新不撤销已获得勋章（earned 一经写入不删）。
//
// 记录键：<period>.<tier>，period ∈ {day,week,month}，tier ∈ {bronze,silver,gold}；
// 集齐成就键为 achievement.all。

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "merit_curve.h"  // 复用日期算术（DaysFromCivil / WeekStartDays / ...）

namespace niuma {
namespace medal {

enum class Period { Day = 0, Week = 1, Month = 2 };

struct Thresholds {
  std::uint64_t day[3];    // bronze, silver, gold
  std::uint64_t week[3];
  std::uint64_t month[3];

  const std::uint64_t *For(Period period) const {
    return period == Period::Day ? day : (period == Period::Week ? week : month);
  }
};

inline Thresholds BuiltinThresholds() {
  // CONTRACT_096 §3 / §7.4 占位值（上线后按 F0 新口径校准）。
  return Thresholds{{5000, 15000, 30000},
                    {30000, 90000, 180000},
                    {120000, 350000, 700000}};
}

inline const char *PeriodName(Period period) {
  switch (period) {
    case Period::Day: return "day";
    case Period::Week: return "week";
    case Period::Month: return "month";
  }
  return "day";
}
inline const char *TierName(int tier) {
  return tier == 0 ? "bronze" : (tier == 1 ? "silver" : "gold");
}
inline std::string MedalKey(Period period, int tier) {
  return std::string(PeriodName(period)) + "." + TierName(tier);
}
inline bool ParseMedalKey(const std::string &key, Period *period, int *tier) {
  const std::size_t dot = key.find('.');
  if (dot == std::string::npos) return false;
  const std::string p = key.substr(0, dot), t = key.substr(dot + 1);
  if (p == "day") *period = Period::Day;
  else if (p == "week") *period = Period::Week;
  else if (p == "month") *period = Period::Month;
  else return false;
  if (t == "bronze") *tier = 0;
  else if (t == "silver") *tier = 1;
  else if (t == "gold") *tier = 2;
  else return false;
  return true;
}

// 单个勋章记录。last_period 为上次计数的自然周期键（跨重启去重，属契约允许的新增字段）。
struct Earned {
  std::string first_earned_day;
  std::uint32_t count = 0;
  std::string last_period;
  bool lit = false;
};
using EarnedMap = std::map<std::string, Earned>;

// 自然周期键。
inline std::string DayPeriodKey(const std::string &date_key) { return date_key; }
inline std::string WeekPeriodKey(int year, int month, int day) {
  const long long days = curve::DaysFromCivil(year, month, day);
  return curve::DateKeyFromDays(curve::WeekStartDays(days));
}
inline std::string MonthPeriodKey(int year, int month) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "%04d-%02d", year, month);
  return std::string(buf);
}

// 给定周期累计值，返回已达到的最高档（-1=无，0=铜，1=银，2=金）。
inline int HighestTier(std::uint64_t value, const std::uint64_t thresholds[3]) {
  if (value >= thresholds[2]) return 2;
  if (value >= thresholds[1]) return 1;
  if (value >= thresholds[0]) return 0;
  return -1;
}

// 对单个勋章按阈值点亮并计次（同周期去重）。
// 返回 true 表示状态发生了变化（新点亮或次数 +1）。
inline bool ApplyMedal(EarnedMap *earned, const std::string &medal_key, std::uint64_t threshold,
                       std::uint64_t value, const std::string &period_key,
                       const std::string &day_key) {
  if (!earned || value < threshold) return false;
  Earned &record = (*earned)[medal_key];
  bool changed = false;
  if (!record.lit) {
    record.lit = true;
    record.first_earned_day = day_key;
    changed = true;
  }
  if (record.last_period != period_key) {
    record.last_period = period_key;
    if (record.count < UINT32_MAX) ++record.count;
    changed = true;
  }
  return changed;
}

// 对一个周期的三个档位求值。
inline bool EvaluatePeriod(EarnedMap *earned, Period period, const Thresholds &thresholds,
                           const std::string &period_key, const std::string &day_key,
                           std::uint64_t value) {
  const std::uint64_t *t = thresholds.For(period);
  bool changed = false;
  for (int tier = 0; tier < 3; ++tier) {
    if (ApplyMedal(earned, MedalKey(period, tier), t[tier], value, period_key, day_key))
      changed = true;
  }
  return changed;
}

// 集齐成就：9 枚全部点亮即解锁。
inline bool AllMedalsLit(const EarnedMap &earned) {
  for (Period period : {Period::Day, Period::Week, Period::Month}) {
    for (int tier = 0; tier < 3; ++tier) {
      auto it = earned.find(MedalKey(period, tier));
      if (it == earned.end() || !it->second.lit || it->second.count == 0) return false;
    }
  }
  return true;
}

// 更新集齐成就；返回是否变化。achievement.all 永久点亮，count 固定记录为 1。
inline bool UpdateAchievement(EarnedMap *earned, const std::string &day_key) {
  if (!earned || !AllMedalsLit(*earned)) return false;
  Earned &achievement = (*earned)["achievement.all"];
  if (achievement.lit) return false;
  achievement.lit = true;
  achievement.first_earned_day = day_key;
  achievement.count = 1;
  achievement.last_period.clear();
  return true;
}

// 汇总一组日键的每日累计（缺失按 0）。
template <class Lookup>
inline std::uint64_t SumRange(const std::vector<std::string> &keys, Lookup lookup) {
  std::uint64_t total = 0;
  for (const std::string &key : keys) {
    std::uint64_t v = lookup(key);
    total = (v > UINT64_MAX - total) ? UINT64_MAX : total + v;
  }
  return total;
}

}  // namespace medal
}  // namespace niuma
