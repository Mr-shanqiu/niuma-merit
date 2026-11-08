#pragma once

// F4 · 牛马曲线 —— 纯算法层（仅标准 C++，可独立单元测试）。
//
// 契约（CONTRACT_096 §2 / §4.3 / §6）：
//   - 每本地日固定 96 个 15 分钟桶，桶 i 覆盖 [i*15, i*15+15) 分钟。
//   - 覆盖标记为 96 位位图（24 个小写十六进制字符）：bit i 位于第 (i>>3) 字节的
//     (7 - (i&7)) 位。用于区分「未采集」与「真实计数为 0」。
//   - 计数一律 uint64。
//   - 保留最近 60 个本地日（含当日），按自然日滚动删除，仅删桶。
//   - 周 = 周一 00:00 至下周一；月 = 当月 1 日至次月 1 日。
//
// 日期用 proleptic Gregorian 自然日序号（days since 1970-01-01）计算，规避
// 时区/DST 影响：调用方负责按事件发生时的本地时区得到 (y,m,d)。UTC 日界一律不用。

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace niuma {
namespace curve {

constexpr int kBucketMinutes = 15;
constexpr int kBucketsPerDay = 96;   // 24*60/15
constexpr int kRetentionDays = 60;

// 分钟（0..1439）→ 桶索引（0..95）；越界钳制。
inline int BucketForMinute(int minute_of_day) {
  if (minute_of_day < 0) return 0;
  if (minute_of_day >= 24 * 60) return kBucketsPerDay - 1;
  return minute_of_day / kBucketMinutes;
}
inline int BucketForSecond(int second_of_day) {
  if (second_of_day < 0) return 0;
  if (second_of_day >= 24 * 3600) return kBucketsPerDay - 1;
  return second_of_day / (kBucketMinutes * 60);
}

// 96 位覆盖位图。
struct Coverage {
  std::array<unsigned char, 12> bytes{};

  void Clear() { bytes.fill(0); }
  bool Get(int index) const {
    if (index < 0 || index >= kBucketsPerDay) return false;
    return (bytes[static_cast<std::size_t>(index >> 3)] &
            static_cast<unsigned char>(0x80u >> (index & 7))) != 0;
  }
  void Set(int index) {
    if (index < 0 || index >= kBucketsPerDay) return;
    bytes[static_cast<std::size_t>(index >> 3)] |=
        static_cast<unsigned char>(0x80u >> (index & 7));
  }
  bool AllZero() const {
    for (unsigned char b : bytes)
      if (b != 0) return false;
    return true;
  }
  int CountSet() const {
    int n = 0;
    for (int i = 0; i < kBucketsPerDay; ++i)
      if (Get(i)) ++n;
    return n;
  }
  // 24 个小写十六进制字符。
  std::string ToHex() const {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(24);
    for (unsigned char b : bytes) {
      out.push_back(kHex[b >> 4]);
      out.push_back(kHex[b & 0x0f]);
    }
    return out;
  }
  static int HexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }
  static bool FromHex(const std::string& hex, Coverage* out) {
    if (!out || hex.size() != 24) return false;
    Coverage result;
    for (int i = 0; i < 12; ++i) {
      int hi = HexValue(hex[static_cast<std::size_t>(i * 2)]);
      int lo = HexValue(hex[static_cast<std::size_t>(i * 2 + 1)]);
      if (hi < 0 || lo < 0) return false;
      result.bytes[static_cast<std::size_t>(i)] = static_cast<unsigned char>((hi << 4) | lo);
    }
    *out = result;
    return true;
  }
};

// 一个本地日的 96 桶 + 覆盖位图。
struct CurveDay {
  std::array<std::uint64_t, kBucketsPerDay> buckets{};
  Coverage coverage;

  void AddCount(int bucket, std::uint64_t delta) {
    if (bucket < 0 || bucket >= kBucketsPerDay || delta == 0) return;
    std::uint64_t& cell = buckets[static_cast<std::size_t>(bucket)];
    cell = (delta > UINT64_MAX - cell) ? UINT64_MAX : cell + delta;
    coverage.Set(bucket);
  }
  void MarkObserved(int bucket) {
    if (bucket < 0 || bucket >= kBucketsPerDay) return;
    coverage.Set(bucket);
  }
  std::uint64_t CoveredSum() const {
    std::uint64_t sum = 0;
    for (int i = 0; i < kBucketsPerDay; ++i)
      if (coverage.Get(i)) {
        std::uint64_t v = buckets[static_cast<std::size_t>(i)];
        sum = (v > UINT64_MAX - sum) ? UINT64_MAX : sum + v;
      }
    return sum;
  }
};

// ---- 日期算术（days since 1970-01-01，proleptic Gregorian）----
inline long long DaysFromCivil(int y, int m, int d) {
  y -= (m <= 2) ? 1 : 0;
  const long long era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy =
      static_cast<unsigned>((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1);
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097LL + static_cast<long long>(doe) - 719468LL;
}
inline void CivilFromDays(long long z, int* y, int* m, int* d) {
  z += 719468;
  const long long era = (z >= 0 ? z : z - 146096) / 146097;
  const unsigned doe = static_cast<unsigned>(z - era * 146097);
  const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int yy = static_cast<int>(yoe) + static_cast<int>(era) * 400;
  const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const unsigned mp = (5 * doy + 2) / 153;
  const int dd = static_cast<int>(doy - (153 * mp + 2) / 5 + 1);
  const int mm = static_cast<int>(mp) + (mp < 10 ? 3 : -9);
  *y = yy + (mm <= 2 ? 1 : 0);
  *m = mm;
  *d = dd;
}
// 周一=0 ... 周日=6。（1970-01-01 为周四）
inline int WeekdayMondayZero(long long days) {
  int w = static_cast<int>((days + 3) % 7);
  if (w < 0) w += 7;
  return w;
}
inline long long WeekStartDays(long long days) { return days - WeekdayMondayZero(days); }

inline std::string FormatDateKey(int y, int m, int d) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02d", y, m, d);
  return std::string(buf);
}
inline std::string DateKeyFromDays(long long days) {
  int y = 0, m = 0, d = 0;
  CivilFromDays(days, &y, &m, &d);
  return FormatDateKey(y, m, d);
}
inline bool ParseDateKey(const std::string& key, int* y, int* m, int* d) {
  if (key.size() != 10 || key[4] != '-' || key[7] != '-') return false;
  int digits[8], count = 0;
  for (std::size_t i = 0; i < key.size(); ++i) {
    if (i == 4 || i == 7) continue;
    if (key[i] < '0' || key[i] > '9') return false;
    digits[count++] = key[i] - '0';
  }
  const int yy = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3];
  const int mm = digits[4] * 10 + digits[5];
  const int dd = digits[6] * 10 + digits[7];
  if (yy < 1 || mm < 1 || mm > 12 || dd < 1 || dd > 31) return false;
  *y = yy;
  *m = mm;
  *d = dd;
  return true;
}
inline bool DateKeyToDays(const std::string& key, long long* out) {
  int y = 0, m = 0, d = 0;
  if (!ParseDateKey(key, &y, &m, &d) || !out) return false;
  *out = DaysFromCivil(y, m, d);
  return true;
}

// 周一–周日 7 个日键（给定本地日）。
inline std::vector<std::string> WeekDayKeys(int y, int m, int d) {
  const long long start = WeekStartDays(DaysFromCivil(y, m, d));
  std::vector<std::string> keys;
  keys.reserve(7);
  for (int i = 0; i < 7; ++i) keys.push_back(DateKeyFromDays(start + i));
  return keys;
}
// 当月所有日键（给定年月）。
inline std::vector<std::string> MonthDayKeys(int y, int m) {
  static const int kLen[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  const bool leap = (y % 400 == 0) || (y % 4 == 0 && y % 100 != 0);
  const int days = kLen[m - 1] + ((m == 2 && leap) ? 1 : 0);
  std::vector<std::string> keys;
  keys.reserve(static_cast<std::size_t>(days));
  for (int day = 1; day <= days; ++day) keys.push_back(FormatDateKey(y, m, day));
  return keys;
}

// 计算需要从 curve.days 删除的日键：早于「今日 - (retention-1)」的键、
// 以及无法解析的坏键。保留窗口 = [today-(retention-1), today]。
inline std::vector<std::string> KeysToPrune(const std::vector<std::string>& keys,
                                            const std::string& today_key,
                                            int retention_days = kRetentionDays) {
  std::vector<std::string> remove;
  long long today = 0;
  if (!DateKeyToDays(today_key, &today)) return remove;  // 无今日锚点则不动
  if (retention_days < 1) retention_days = 1;
  const long long earliest = today - static_cast<long long>(retention_days) + 1;
  for (const std::string& key : keys) {
    long long days = 0;
    if (!DateKeyToDays(key, &days)) {
      remove.push_back(key);  // 坏键清理
      continue;
    }
    if (days < earliest) remove.push_back(key);
  }
  return remove;
}

}  // namespace curve
}  // namespace niuma
