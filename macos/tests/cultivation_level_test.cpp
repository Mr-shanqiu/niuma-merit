// 独立纯算法自测：修行等级（FB10 / D22）。
// 编译：clang++ -std=c++17 -I ../../src cultivation_level_test.cpp -o /tmp/cl_test
#include "cultivation_level.h"

#include <cstdint>
#include <cstdio>

using namespace niuma::cultivation;

static int g_fail = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);         \
      ++g_fail;                                                           \
    }                                                                     \
  } while (0)

int main() {
  // 边界：门槛起点的归属等级。
  CHECK(Evaluate(0).level == 0);       // 香客
  CHECK(Evaluate(99).level == 0);
  CHECK(Evaluate(100).level == 1);     // 居士
  CHECK(Evaluate(499).level == 1);
  CHECK(Evaluate(500).level == 2);     // 行者
  CHECK(Evaluate(1999).level == 2);
  CHECK(Evaluate(2000).level == 3);    // 苦行僧
  CHECK(Evaluate(7999).level == 3);
  CHECK(Evaluate(8000).level == 4);    // 高僧
  CHECK(Evaluate(29999).level == 4);
  CHECK(Evaluate(30000).level == 5);   // 宗师
  CHECK(Evaluate(100000000ULL).level == 5);

  // 进度 / 距下一级。
  {
    Status s = Evaluate(0);            // 香客 0 → 居士 100
    CHECK(!s.max_level);
    CHECK(s.current_threshold == 0 && s.next_threshold == 100);
    CHECK(s.remaining == 100);
    CHECK(s.progress > -1e-9 && s.progress < 1e-9);
  }
  {
    Status s = Evaluate(50);           // 0→100 中间
    CHECK(s.remaining == 50);
    CHECK(s.progress > 0.49 && s.progress < 0.51);
  }
  {
    Status s = Evaluate(2500);         // 苦行僧 2000 → 高僧 8000，跨度 6000
    CHECK(s.level == 3);
    CHECK(s.next_threshold == 8000);
    CHECK(s.remaining == 5500);
    CHECK(s.progress > 0.083 && s.progress < 0.084);
  }
  // 满级：宗师 · 功德圆满（remaining=0, progress=1）。
  {
    Status s = Evaluate(30000);
    CHECK(s.max_level);
    CHECK(s.level == 5);
    CHECK(s.remaining == 0);
    CHECK(s.progress == 1.0);
  }

  if (g_fail == 0) std::printf("cultivation_level_test: OK\n");
  else std::printf("cultivation_level_test: %d FAILURES\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
