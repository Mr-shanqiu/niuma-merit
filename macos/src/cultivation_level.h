#pragma once

// FB10 · 修行等级（D22）——纯算法层（仅标准 C++，可独立单元测试）。
//
// 用中性修行隐喻，**不出现「佛/菩萨/罗汉」等神祇字眼**。
// 成长值 = 累计功德总数（lifetime total；不随换形象/清空日历变化，由调用方持久化）。
// 等级阶梯（累计功德门槛，可调）：
//   1 香客 0 / 2 居士 5000 / 3 行者 50000 / 4 苦行僧 400000 / 5 高僧 2000000 / 6 宗师 8000000
// （按约 4 万次/工作日重估：居士≈2h、行者≈1.5天、苦行僧≈2周、高僧≈2.5月、宗师≈8-10月）
// 称号的本地化（zh-Hans/zh-Hant/ja/en）在 UI 层用 UiText 完成；本层只给等级序号。

#include <cstdint>

namespace niuma {
namespace cultivation {

constexpr int kLevelCount = 6;

// 累计功德门槛（升序）；索引 0 对应等级 1（香客）。
inline const std::uint64_t *Thresholds() {
  static const std::uint64_t kThresholds[kLevelCount] = {0, 5000, 50000, 400000, 2000000, 8000000};
  return kThresholds;
}

// 一次求值结果。
struct Status {
  std::uint64_t merit = 0;           // 累计功德
  int level = 0;                     // 当前等级索引 0..kLevelCount-1（0=香客）
  std::uint64_t current_threshold = 0;
  std::uint64_t next_threshold = 0;  // 满级时等于当前门槛
  std::uint64_t remaining = 0;       // 距下一级还差多少功德（满级为 0）
  bool max_level = false;
  double progress = 0.0;             // 当前等级内的进度 0..1（满级为 1）
};

inline Status Evaluate(std::uint64_t merit) {
  const std::uint64_t *t = Thresholds();
  Status s;
  s.merit = merit;
  int level = 0;
  for (int i = 0; i < kLevelCount; ++i)
    if (merit >= t[i]) level = i;
  s.level = level;
  s.current_threshold = t[level];
  if (level >= kLevelCount - 1) {
    s.max_level = true;
    s.next_threshold = t[level];
    s.remaining = 0;
    s.progress = 1.0;
    return s;
  }
  s.next_threshold = t[level + 1];
  s.remaining = s.next_threshold - merit;
  const std::uint64_t span = s.next_threshold - s.current_threshold;
  s.progress = span > 0
      ? static_cast<double>(merit - s.current_threshold) / static_cast<double>(span)
      : 0.0;
  return s;
}

}  // namespace cultivation
}  // namespace niuma
