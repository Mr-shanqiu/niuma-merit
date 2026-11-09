// 独立纯算法自测：F0 距离刻度计数 + F4 分钟归桶 / 覆盖心跳 / 日期切换。
// 编译：clang++ -std=c++17 -I ../src/client/core input_state_test.cpp -o /tmp/is_test
// 或直接运行 windows/tests/run_tests.sh。
#include "input_state.h"

#include <cstdint>
#include <cstdio>
#include <vector>

using niuma::client::core::CurveDayRecord;
using niuma::client::core::InputCore;
using niuma::client::core::InputEvent;
using niuma::client::core::InputKind;
using niuma::client::core::ObserveResult;

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

static InputEvent Event(InputKind kind, std::uint64_t ms, std::uint32_t date,
                        int ticks = 0, int minute = -1) {
  InputEvent e;
  e.kind = kind;
  e.monotonicMs = ms;
  e.date = date;
  e.scrollTicks = ticks;
  e.minuteOfDay = minute;
  return e;
}

int main() {
  constexpr std::uint32_t kDay = 20261109;

  // --- F0: scroll_ticks 0 → Ignored，total 不变 ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    const auto before = core.snapshot().total;
    CHECK(core.Observe(Event(InputKind::Scroll, 1000, kDay, 0)) == ObserveResult::Ignored);
    CHECK(core.snapshot().total == before);
    CHECK(core.snapshot().today == before);
  }

  // --- F0: scroll_ticks 1/4 → total/today 增加 N ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.Observe(Event(InputKind::Scroll, 1000, kDay, 1)) == ObserveResult::Counted);
    CHECK(core.snapshot().total == 1);
    CHECK(core.snapshot().today == 1);
    CHECK(core.Observe(Event(InputKind::Scroll, 1010, kDay, 4)) == ObserveResult::Counted);
    CHECK(core.snapshot().total == 5);
    CHECK(core.snapshot().today == 5);
  }

  // --- F0: 负刻度视为无效（不计数，不报错） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.Observe(Event(InputKind::Scroll, 1000, kDay, -3)) == ObserveResult::Ignored);
    CHECK(core.snapshot().total == 0);
  }

  // --- 非 Scroll 事件不受 scroll_ticks 影响（每次计 1） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.Observe(Event(InputKind::Click, 1000, kDay, 0)) == ObserveResult::Counted);
    CHECK(core.snapshot().total == 1);
    CHECK(core.Observe(Event(InputKind::KeyDown, 1010, kDay, 0)) == ObserveResult::Counted);
    CHECK(core.snapshot().total == 2);
    CHECK(core.Observe(Event(InputKind::KeyUp, 1020, kDay, 0)) == ObserveResult::Ignored);
    CHECK(core.snapshot().total == 2);
  }

  // --- F4: 分钟归桶边界（14:59→59 / 15:00→60 / 23:59→95 / 00:00 次日→0） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    // 14:59 = 14*60+59 = 899 → 桶 59
    CHECK(core.Observe(Event(InputKind::Click, 1000, kDay, 0, 899)) == ObserveResult::Counted);
    // 15:00 = 900 → 桶 60
    CHECK(core.Observe(Event(InputKind::Click, 1010, kDay, 0, 900)) == ObserveResult::Counted);
    // 23:59 = 1439 → 桶 95
    CHECK(core.Observe(Event(InputKind::Click, 1020, kDay, 0, 1439)) == ObserveResult::Counted);
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 1);
    CHECK(out[0].date == kDay);
    CHECK(out[0].day.buckets[59] == 1);
    CHECK(out[0].day.buckets[60] == 1);
    CHECK(out[0].day.buckets[95] == 1);
    CHECK(out[0].day.coverage.Get(59));
    CHECK(out[0].day.coverage.Get(60));
    CHECK(out[0].day.coverage.Get(95));
    CHECK(out[0].day.CoveredSum() == 3);
  }

  // --- F4: 同一桶多次相加，覆盖=1 ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    // 3 次 click 落在 09:0x（桶 36）
    CHECK(core.Observe(Event(InputKind::Click, 1000, kDay, 0, 9 * 60 + 1)) == ObserveResult::Counted);
    CHECK(core.Observe(Event(InputKind::Click, 1010, kDay, 0, 9 * 60 + 7)) == ObserveResult::Counted);
    CHECK(core.Observe(Event(InputKind::Click, 1020, kDay, 0, 9 * 60 + 14)) == ObserveResult::Counted);
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 1);
    CHECK(out[0].day.buckets[36] == 3);
    CHECK(out[0].day.coverage.CountSet() == 1);
  }

  // --- F4: minuteOfDay = -1 → 会计入 total/today 但不进桶 ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.Observe(Event(InputKind::Click, 1000, kDay, 0, -1)) == ObserveResult::Counted);
    CHECK(core.snapshot().total == 1);
    CHECK(core.curve_size() == 0);
  }

  // --- F4: 心跳 MarkCurveObserved → coverage=1 且 bucket=0（真零） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.MarkCurveObserved(kDay, 10 * 60));  // 桶 40
    CHECK(!core.MarkCurveObserved(kDay, -1));       // 非法
    CHECK(!core.MarkCurveObserved(kDay, 24 * 60));  // 非法
    CHECK(!core.MarkCurveObserved(0, 0));           // 非法日期
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 1);
    CHECK(out[0].day.coverage.Get(40));
    CHECK(out[0].day.buckets[40] == 0);
    CHECK(out[0].day.CoveredSum() == 0);
    CHECK(core.snapshot().total == 0);  // 心跳不增加计数
  }

  // --- F4: 跨天（23:59 旧日 vs 00:00 新日分组）+ 日期环 ---
  {
    InputCore core;
    constexpr std::uint32_t kNext = 20261110;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    CHECK(core.Observe(Event(InputKind::Click, 1000, kDay, 0, 1439)) == ObserveResult::Counted);
    CHECK(core.Observe(Event(InputKind::Click, 2000, kNext, 0, 0)) == ObserveResult::Counted);
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 2);
    bool sawOld = false, sawNew = false;
    for (std::size_t i = 0; i < 2; ++i) {
      if (out[i].date == kDay) {
        sawOld = true;
        CHECK(out[i].day.buckets[95] == 1);
      } else if (out[i].date == kNext) {
        sawNew = true;
        CHECK(out[i].day.buckets[0] == 1);
      }
    }
    CHECK(sawOld && sawNew);
    CHECK(core.snapshot().today == 1);  // 新日 today 只为新日计数
  }

  // --- F4: 环容量滚动（第 65 个不同日挤掉最旧） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, 20260101, nullptr, 0));
    // 生成 70 个连续日键，各 heartbeat 一次。
    std::uint32_t d = 20260101;
    int created = 0;
    for (int i = 0; i < 70; ++i) {
      // 简单日期递增（本测试只需有效日键且互不相同；用 curve 的日期算术更稳）。
      long long days = niuma::curve::DaysFromCivil(d / 10000, (d / 100) % 100, d % 100);
      const long long next = days + 1;
      int y = 0, m = 0, dd = 0;
      niuma::curve::CivilFromDays(next, &y, &m, &dd);
      d = static_cast<std::uint32_t>(y) * 10000 + static_cast<std::uint32_t>(m) * 100 +
          static_cast<std::uint32_t>(dd);
      if (core.MarkCurveObserved(d, 0)) ++created;
    }
    CHECK(created == 70);
    // 环容量 64：curve_size 不超过 64。
    CHECK(core.curve_size() <= InputCore::kCurveDayCapacity);
    // CopyCurveDays 必须要求请求容量如实返回 required。
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 64);
    // 容量不足时返回 required 且不写。
    CHECK(core.CopyCurveDays(out, 10) == 64);
  }

  // --- daily total 与 CoveredSum 一致（同一批计数） ---
  {
    InputCore core;
    CHECK(core.Initialize(0, kDay, nullptr, 0));
    const int minutes[] = {0, 899, 900, 1439, 720};
    for (int i = 0; i < 5; ++i) {
      for (int k = 1; k <= 2; ++k)
        CHECK(core.Observe(Event(InputKind::Click, 1000 + i * 10 + k, kDay, 0, minutes[i])) ==
              ObserveResult::Counted);
    }
    CHECK(core.snapshot().today == 10);
    CurveDayRecord out[InputCore::kCurveDayCapacity];
    CHECK(core.CopyCurveDays(out, InputCore::kCurveDayCapacity) == 1);
    CHECK(out[0].day.CoveredSum() == 10);
  }

  if (g_fail == 0) {
    std::printf("input_state_test: OK (%d checks)\n", g_checks);
    return 0;
  }
  std::printf("input_state_test: FAILED (%d/%d)\n", g_fail, g_checks);
  return 1;
}
