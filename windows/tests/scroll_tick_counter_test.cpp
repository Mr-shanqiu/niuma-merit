// 独立纯算法自测：F0 滚动距离折算/余量/单事件与单手势上限。
// 编译：clang++ -std=c++17 -I ../src/client/core scroll_tick_counter_test.cpp -o /tmp/st_test
// 或直接运行 windows/tests/run_tests.sh。
#include "scroll_tick_counter.h"

#include <cstdint>
#include <cstdio>
#include <limits>

using niuma::client::core::ScrollTickCounter;

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
  // --- 常量与 macOS 对齐 ---
  CHECK(ScrollTickCounter::kWheelDelta == 120);
  CHECK(ScrollTickCounter::kMaxTicksPerEvent == 4);
  CHECK(ScrollTickCounter::kMaxTicksPerGesture == 30);
  CHECK(ScrollTickCounter::kIdleGestureGapMs == 350);

  // --- 初始状态与首条事件 ---
  {
    ScrollTickCounter counter;
    CHECK(!counter.active());
    CHECK(counter.gesture_ticks() == 0);
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(0, false) == 0);  // 首条事件自动开启手势
    CHECK(counter.active());
    CHECK(counter.Consume(120, false) == 1);
  }

  // --- 每 120 delta = 1 刻度；整数倍 ---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(120, false) == 1);
    CHECK(counter.residue() == 0);
    CHECK(counter.gesture_ticks() == 1);
    CHECK(counter.Consume(240, false) == 2);
    CHECK(counter.gesture_ticks() == 3);
    CHECK(counter.Consume(360, false) == 3);
    CHECK(counter.gesture_ticks() == 6);
  }

  // --- 亚刻度余量跨事件累计 ---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(60, false) == 0);
    CHECK(counter.residue() == 60);
    CHECK(counter.Consume(60, false) == 1);
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(30, false) == 0);
    CHECK(counter.Consume(90, false) == 1);
    CHECK(counter.Consume(119, false) == 0);
    CHECK(counter.residue() == 119);
    CHECK(counter.Consume(1, false) == 1);
    CHECK(counter.residue() == 0);
  }

  // --- 方向不敏感（上/下、水平/垂直都按 |delta|）---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(-120, false) == 1);
    CHECK(counter.Consume(-240, false) == 2);
    CHECK(counter.Consume(120, false) == 1);
    CHECK(counter.gesture_ticks() == 4);
  }
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(-60, false) == 0);
    CHECK(counter.Consume(60, false) == 1);  // 反方向仍共享同一余量
  }

  // --- 单事件上限：最多 4 刻度；异常跳变不保留余量 ---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(480, false) == 4);
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(960, false) == 4);  // 8 刻度被截为 4
    CHECK(counter.residue() == 0);            // 960 的剩余 4 刻度不保留
    CHECK(counter.Consume(120, false) == 1);  // 下一条正常事件只算 1
    CHECK(counter.gesture_ticks() == 9);
  }
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(60, false) == 0);
    CHECK(counter.residue() == 60);
    CHECK(counter.Consume(600, false) == 4);  // 异常跳变先清余量再截断
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(119, false) == 0);
    CHECK(counter.Consume(1, false) == 1);
  }
  {
    // INT_MIN 取绝对值不溢出。
    ScrollTickCounter counter;
    CHECK(counter.Consume(std::numeric_limits<int>::min(), false) == 4);
    CHECK(counter.residue() == 0);
  }

  // --- 单手势上限：30 刻度封顶，新手势重新计数 ---
  {
    ScrollTickCounter counter;
    int total = 0;
    for (int i = 0; i < 7; ++i) total += counter.Consume(480, false);  // 7*4 = 28
    CHECK(total == 28);
    CHECK(counter.gesture_ticks() == 28);
    CHECK(counter.Consume(480, false) == 2);  // 只到 30
    CHECK(counter.gesture_ticks() == 30);
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(480, false) == 0);  // 已封顶
    CHECK(counter.Consume(120, false) == 0);
    CHECK(counter.gesture_ticks() == 30);
    // 手指重新落下 = 新手势。
    counter.BeginGesture();
    CHECK(counter.gesture_ticks() == 0);
    CHECK(counter.Consume(480, false) == 4);
    // 通过 new_gesture=true 也能重新开始。
    CHECK(counter.Consume(120, true) == 1);
    CHECK(counter.gesture_ticks() == 1);
  }

  // --- 手势边界由调用方传入：new_gesture 清空亚刻度余量 ---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(119, false) == 0);
    CHECK(counter.residue() == 119);
    CHECK(counter.Consume(1, true) == 0);  // 新手势丢弃上一条的 119
    CHECK(counter.residue() == 1);
    CHECK(counter.Consume(119, false) == 1);
    CHECK(counter.gesture_ticks() == 1);
  }
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(119, false) == 0);
    counter.BeginGesture();
    CHECK(counter.residue() == 0);
    CHECK(counter.Consume(119, false) == 0);
    CHECK(counter.Consume(1, false) == 1);
  }

  // --- 空闲判定辅助（Windows 无 scrollPhase 时的边界近似）---
  CHECK(!ScrollTickCounter::IdleGapExceeded(1000, 1350));  // 恰好 350ms：同一手势
  CHECK(ScrollTickCounter::IdleGapExceeded(1000, 1351));
  CHECK(ScrollTickCounter::IdleGapExceeded(0, 351));
  CHECK(!ScrollTickCounter::IdleGapExceeded(1000, 1000));
  CHECK(!ScrollTickCounter::IdleGapExceeded(1000, 999));  // 时钟回退：不开启新手势

  // --- 0 delta 不消耗手势预算、不改变余量 ---
  {
    ScrollTickCounter counter;
    CHECK(counter.Consume(0, false) == 0);
    CHECK(counter.gesture_ticks() == 0);
    CHECK(counter.Consume(0, true) == 0);
    CHECK(counter.Consume(480, false) == 4);
  }

  // --- 大量小增量：每满 120 才计 1，不丢余量 ---
  {
    ScrollTickCounter counter;
    int total = 0;
    for (int i = 0; i < 120; ++i) total += counter.Consume(1, false);
    CHECK(total == 1);
    CHECK(counter.residue() == 0);
    for (int i = 0; i < 119; ++i) total += counter.Consume(1, false);
    CHECK(total == 1);
    CHECK(counter.residue() == 119);
    total += counter.Consume(1, false);
    CHECK(total == 2);
  }

  // --- 任意输入下返回值都在 [0,4]，余量始终 <120 ---
  {
    for (int delta = -2000; delta <= 2000; delta += 7) {
      ScrollTickCounter counter;
      const int ticks = counter.Consume(delta, true);
      CHECK(ticks >= 0 && ticks <= ScrollTickCounter::kMaxTicksPerEvent);
      CHECK(counter.residue() < static_cast<std::uint64_t>(ScrollTickCounter::kWheelDelta));
    }
  }

  if (g_fail == 0) std::printf("scroll_tick_counter_test: OK (%d checks)\n", g_checks);
  else std::printf("scroll_tick_counter_test: %d FAILURES (%d checks)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
