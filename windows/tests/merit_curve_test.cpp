// 独立纯算法自测：牛马曲线分桶/覆盖位图/日期与滚删（F4）。
// 编译：clang++ -std=c++17 -I ../src/client/core merit_curve_test.cpp -o /tmp/mc_test
// 或直接运行 windows/tests/run_tests.sh。
#include "merit_curve.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace niuma::curve;

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
  // --- 桶边界（§2.2）---
  CHECK(BucketForMinute(0) == 0);
  CHECK(BucketForMinute(14) == 0);
  CHECK(BucketForMinute(15) == 1);
  CHECK(BucketForMinute(14 * 60 + 59) == 59);  // 14:59 -> 59
  CHECK(BucketForMinute(15 * 60) == 60);        // 15:00 -> 60
  CHECK(BucketForMinute(23 * 60 + 59) == 95);   // 23:59 -> 95
  CHECK(BucketForSecond(15 * 3600) == 60);
  CHECK(BucketForSecond(14 * 3600 + 59 * 60 + 59) == 59);
  CHECK(BucketForSecond(15 * 60 - 1) == 0);
  CHECK(BucketForSecond(15 * 60) == 1);
  CHECK(BucketForMinute(-5) == 0);
  CHECK(BucketForMinute(24 * 60) == 95);
  CHECK(BucketForSecond(-1) == 0);
  CHECK(BucketForSecond(24 * 3600) == 95);
  // 96 个桶的左右边界逐一核对：桶 i = [i*15, i*15+15) 分钟。
  for (int i = 0; i < kBucketsPerDay; ++i) {
    CHECK(BucketForMinute(i * 15) == i);
    CHECK(BucketForMinute(i * 15 + 14) == i);
    CHECK(BucketForSecond(i * 15 * 60) == i);
    CHECK(BucketForSecond((i * 15 + 14) * 60 + 59) == i);
  }

  // --- 覆盖位图 bit 序：首字节最高位=桶0 ---
  Coverage cov;
  CHECK(cov.ToHex() == "000000000000000000000000");
  CHECK(cov.AllZero());
  CHECK(cov.CountSet() == 0);
  cov.Set(0);
  CHECK(cov.Get(0));
  CHECK(!cov.AllZero());
  CHECK(cov.ToHex().substr(0, 2) == "80");  // 0x80
  cov.Set(7);
  CHECK(cov.ToHex().substr(0, 2) == "81");  // bit7 -> 0x01
  cov.Clear();
  CHECK(cov.AllZero());
  // 越界索引：读 false、写 no-op。
  cov.Set(-1);
  cov.Set(96);
  CHECK(cov.AllZero());
  CHECK(!cov.Get(-1));
  CHECK(!cov.Get(96));
  Coverage cov2;
  CHECK(Coverage::FromHex("800000000000000000000001", &cov2));
  CHECK(cov2.Get(0));
  CHECK(!cov2.Get(1));
  CHECK(cov2.Get(95));  // 末字节最低位 = bit95
  CHECK(cov2.CountSet() == 2);
  // 大写十六进制也接受。
  Coverage upper;
  CHECK(Coverage::FromHex("FFFFFFFFFFFFFFFFFFFFFFFF", &upper));
  CHECK(upper.CountSet() == 96);
  CHECK(upper.ToHex() == std::string(24, 'f'));  // 输出统一小写
  // 拒绝坏长度/坏字符。
  Coverage bad;
  CHECK(!Coverage::FromHex("80", &bad));
  CHECK(!Coverage::FromHex("zzzzzzzzzzzzzzzzzzzzzzzz", &bad));
  CHECK(!Coverage::FromHex("", &bad));
  CHECK(!Coverage::FromHex("80000000000000000000000", &bad));  // 23 字符
  CHECK(!Coverage::FromHex(std::string(24, 'f'), nullptr));

  // 全部 96 位往返。
  Coverage full;
  for (int i = 0; i < kBucketsPerDay; ++i) full.Set(i);
  CHECK(full.ToHex() == std::string(24, 'f'));
  CHECK(full.CountSet() == 96);
  Coverage round;
  CHECK(Coverage::FromHex(full.ToHex(), &round));
  CHECK(round.CountSet() == 96);

  // --- CurveDay 计数/覆盖/饱和 ---
  CurveDay day;
  day.AddCount(59, 12);
  CHECK(day.buckets[59] == 12);
  CHECK(day.coverage.Get(59));
  CHECK(!day.coverage.Get(58));  // 未采集
  CHECK(day.CoveredSum() == 12);
  day.AddCount(59, UINT64_MAX);  // 饱和
  CHECK(day.buckets[59] == UINT64_MAX);
  CHECK(day.CoveredSum() == UINT64_MAX);
  day.MarkObserved(10);  // 真零：覆盖=1 计数=0
  CHECK(day.coverage.Get(10) && day.buckets[10] == 0);
  // 加 0 不产生覆盖（未采集 != 真零）。
  day.AddCount(11, 0);
  CHECK(!day.coverage.Get(11));
  // 越界桶忽略。
  day.AddCount(-1, 5);
  day.AddCount(96, 5);
  CHECK(day.CoveredSum() == UINT64_MAX);
  // CoveredSum 只统计已覆盖桶：直接写入未覆盖桶不影响合计。
  CurveDay partial;
  partial.buckets[3] = 100;  // 未覆盖 -> 不计入
  CHECK(partial.CoveredSum() == 0);
  partial.MarkObserved(3);
  CHECK(partial.CoveredSum() == 100);
  // 未覆盖桶必须为 0 的契约由序列化端保证；算法层只按 coverage 汇总。

  // --- 日期往返 ---
  int y = 0, m = 0, d = 0;
  CHECK(ParseDateKey("2026-11-08", &y, &m, &d));
  CHECK(y == 2026 && m == 11 && d == 8);
  long long days = DaysFromCivil(2026, 11, 8);
  CHECK(DateKeyFromDays(days) == "2026-11-08");
  long long back = 0;
  CHECK(DateKeyToDays("2026-11-08", &back) && back == days);
  int ry, rm, rd;
  CivilFromDays(days, &ry, &rm, &rd);
  CHECK(ry == 2026 && rm == 11 && rd == 8);
  // 1970-01-01 为第 0 天（周四）。
  CHECK(DaysFromCivil(1970, 1, 1) == 0);
  CHECK(WeekdayMondayZero(0) == 3);
  CHECK(DateKeyFromDays(0) == "1970-01-01");
  // 坏键拒绝。
  CHECK(!ParseDateKey("2026-1-08", &y, &m, &d));
  CHECK(!ParseDateKey("2026-11-8", &y, &m, &d));
  CHECK(!ParseDateKey("2026/11/08", &y, &m, &d));
  CHECK(!ParseDateKey("2026-13-08", &y, &m, &d));
  CHECK(!ParseDateKey("2026-00-08", &y, &m, &d));
  CHECK(!ParseDateKey("2026-11-00", &y, &m, &d));
  CHECK(!ParseDateKey("2026-11-32", &y, &m, &d));
  CHECK(!ParseDateKey("abcd-ef-gh", &y, &m, &d));

  // --- 周一为一周起点（2026-11-08 是周日）---
  CHECK(WeekdayMondayZero(DaysFromCivil(2026, 11, 8)) == 6);  // Sunday
  std::vector<std::string> week = WeekDayKeys(2026, 11, 8);
  CHECK(week.size() == 7);
  CHECK(week.front() == "2026-11-02");  // 周一
  CHECK(week.back() == "2026-11-08");   // 周日
  // 周内任意一天得到同一组
  CHECK(WeekDayKeys(2026, 11, 4).front() == "2026-11-02");
  // 周一自身
  CHECK(WeekDayKeys(2026, 11, 2).front() == "2026-11-02");

  // --- 自然月日数（含闰年 2 月）---
  CHECK(MonthDayKeys(2026, 11).size() == 30);
  CHECK(MonthDayKeys(2026, 2).size() == 28);
  CHECK(MonthDayKeys(2024, 2).size() == 29);  // 闰年
  CHECK(MonthDayKeys(2000, 2).size() == 29);  // 400 年闰
  CHECK(MonthDayKeys(1900, 2).size() == 28);  // 100 年不闰
  CHECK(MonthDayKeys(2026, 1).front() == "2026-01-01");
  CHECK(MonthDayKeys(2026, 1).back() == "2026-01-31");
  CHECK(MonthDayKeys(2026, 12).back() == "2026-12-31");

  // --- 60 天滚删（含当日）：早于 today-59 删除 ---
  std::vector<std::string> keys;
  for (int offset = 0; offset <= 70; ++offset)
    keys.push_back(DateKeyFromDays(DaysFromCivil(2026, 11, 8) - offset));
  std::vector<std::string> pruned = KeysToPrune(keys, "2026-11-08", 60);
  // 应删除 offset 60..70 共 11 个
  CHECK(pruned.size() == 11);
  // 边界：offset 59 保留，offset 60 删除
  std::vector<std::string> boundary = {
      DateKeyFromDays(DaysFromCivil(2026, 11, 8) - 59),
      DateKeyFromDays(DaysFromCivil(2026, 11, 8) - 60)};
  std::vector<std::string> bp = KeysToPrune(boundary, "2026-11-08", 60);
  CHECK(bp.size() == 1);
  CHECK(bp[0] == DateKeyFromDays(DaysFromCivil(2026, 11, 8) - 60));
  // 恰好 60 个自然日全部保留。
  std::vector<std::string> exactly;
  for (int offset = 0; offset < 60; ++offset)
    exactly.push_back(DateKeyFromDays(DaysFromCivil(2026, 11, 8) - offset));
  CHECK(KeysToPrune(exactly, "2026-11-08", 60).empty());
  // 坏键清理
  std::vector<std::string> badKeys = {"not-a-date", "2026-11-08"};
  CHECK(KeysToPrune(badKeys, "2026-11-08", 60).size() == 1);
  // 今日键无效时不动（避免误删全部）。
  CHECK(KeysToPrune(keys, "bad-today", 60).empty());
  // retention 下限钳制为 1：只保留今日，昨日与更早都删除。
  CHECK(KeysToPrune(boundary, "2026-11-08", 0).size() == 2);

  // --- 跨年周/月 ---
  // 2026-12-31 之后的周一属于 2027 周；2027-01-01 是周五。
  std::vector<std::string> ny = WeekDayKeys(2027, 1, 1);
  CHECK(ny.front() == "2026-12-28");  // 周一落在上一年
  CHECK(ny.size() == 7);
  CHECK(MonthDayKeys(2026, 12).back() == "2026-12-31");

  if (g_fail == 0) std::printf("merit_curve_test: OK (%d checks)\n", g_checks);
  else std::printf("merit_curve_test: %d FAILURES (%d checks)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
