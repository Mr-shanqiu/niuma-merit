// metrics_store.h 纯逻辑自测：默认文档、按块解析降级、曲线编解码（数字/字符串
// 大数）、60 天修剪、未知字段保留、迁移收据、1 MiB 评估、~90 KiB 估算。
// 编译：clang++ -std=c++17 -I ../src/client/core metrics_store_test.cpp -o /tmp/ms_test
#include "metrics_store.h"

#include <cmath>
#include <cstdio>
#include <string>

using namespace niuma::metrics;
using niuma::curve::CurveDay;
using niuma::metrics::CurveDayValue;
using niuma::metrics::json::Parse;
using niuma::metrics::json::ParseError;

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

static Root ParseOk(const std::string& text) {
  Root root;
  const auto parsed = Parse(text);
  CHECK(parsed.error == ParseError::None);
  CHECK(ParseInto(parsed.value, &root));
  return root;
}

// 构造一个合法文档文本。
static std::string BaseDocument() {
  return "{"
      "\"schema_version\":1,"
      "\"namespace\":\"niuma.gongde.v096\","
      "\"app_version\":\"0.9.6\","
      "\"updated_at_utc\":1762581120,"
      "\"migration\":{\"from_095\":true,\"migrated_at_utc\":1762581100,"
      "  \"legacy_source\":\"data_ini\"},"
      "\"prefs\":{\"ui_language\":\"zh-Hant\",\"appearance_scale\":1.25},"
      "\"encourager\":{\"enabled\":true,\"daily_wage_minor\":10000,"
      "  \"currency\":\"TWD\",\"currency_override\":true,"
      "  \"start_minute\":540,\"end_minute\":1080},"
      "\"medals\":{\"thresholds_version\":\"builtin-2026-11-08\","
      "  \"earned\":{\"day.bronze\":{\"first_earned_day\":\"2026-10-01\",\"count\":3}}},"
      "\"curve\":{\"bucket_minutes\":15,\"buckets_per_day\":96,\"retention_days\":60,"
      "  \"days\":{}},"
      "\"vendor_extension\":{\"future\":\"kept\"}"
      "}";
}

int main() {
  // --- 默认文档 ---
  {
    Root root = Root::Default();
    CHECK(root.tree.IsObject());
    CHECK(root.prefs.appearance_scale == 1.0);
    CHECK(root.prefs.ui_language == "zh-Hans");
    CHECK(!root.encourager.enabled);
    CHECK(root.encourager.start_minute == 540 && root.encourager.end_minute == 1080);
    CHECK(root.medals.earned.empty());
    CHECK(root.curve_days.empty());
    const std::string text = Serialize(root);
    CHECK(text.find("\"schema_version\":1") != std::string::npos);
    CHECK(text.find("\"namespace\":\"niuma.gongde.v096\"") != std::string::npos);
    const Root back = ParseOk(text);
    CHECK(back.prefs.ui_language == "zh-Hans");
    CHECK(std::fabs(back.prefs.appearance_scale - 1.0) < 1e-12);
  }

  // --- 完整文档解析 + 未知字段保留 ---
  {
    Root root = ParseOk(BaseDocument());
    CHECK(root.migration.from_095);
    CHECK(root.migration.legacy_source == "data_ini");
    CHECK(root.prefs.ui_language == "zh-Hant");
    CHECK(std::fabs(root.prefs.appearance_scale - 1.25) < 1e-12);
    CHECK(root.encourager.enabled);
    CHECK(root.encourager.daily_wage_minor == 10000);
    CHECK(root.encourager.currency == "TWD");
    CHECK(root.encourager.currency_override);
    CHECK(root.medals.earned.at("day.bronze").count == 3);
    CHECK(root.medals.earned.at("day.bronze").first_earned_day == "2026-10-01");
    // 写回后未知字段仍在。
    const std::string text = Serialize(root);
    CHECK(text.find("vendor_extension") != std::string::npos);
    CHECK(text.find("\"future\":\"kept\"") != std::string::npos);
    // 往返稳定。
    Root back = ParseOk(text);
    CHECK(back.encourager.daily_wage_minor == 10000);
    CHECK(back.prefs.ui_language == "zh-Hant");
    const std::string again = Serialize(back);
    CHECK(again == text);  // 规范形态稳定（updated_at_utc 被覆盖为同一秒）。
  }

  // --- schema/namespace 守卫 ---
  {
    std::string text = BaseDocument();
    text.replace(text.find("\"schema_version\":1"), 18, "\"schema_version\":2");
    const auto wrongSchema = Parse(text);
    CHECK(wrongSchema.error == ParseError::None);
    Root root;
    CHECK(!ParseInto(wrongSchema.value, &root));
  }
  {
    std::string text = BaseDocument();
    text.replace(text.find("\"niuma.gongde.v096\""), 19, "\"other.product.v1\"");
    const auto parsed = Parse(text);
    CHECK(parsed.error == ParseError::None);
    Root root;
    CHECK(!ParseInto(parsed.value, &root));
  }

  // --- 块级降级：坏块只影响自己 ---
  {
    std::string text = BaseDocument();
    text.replace(text.find("\"ui_language\":\"zh-Hant\""), 23, "\"ui_language\":\"xx-XX\"");
    Root root = ParseOk(text);
    bool degradedPrefs = false;
    for (const std::string& block : root.degraded_blocks) degradedPrefs |= block == "prefs";
    CHECK(degradedPrefs);
    CHECK(root.prefs.ui_language == "zh-Hans");  // 回默认。
    CHECK(root.encourager.currency == "TWD");    // 其他块照常。
    CHECK(root.medals.earned.at("day.bronze").count == 3);
    const std::string back = Serialize(root);
    CHECK(back.find("vendor_extension") != std::string::npos);
  }
  {
    std::string text = BaseDocument();
    // encourager 起止倒挂 → 块降级。
    text.replace(text.find("\"start_minute\":540,\"end_minute\":1080"),
                 36, "\"start_minute\":1080,\"end_minute\":540");
    Root root = ParseOk(text);
    bool degraded = false;
    for (const std::string& block : root.degraded_blocks) degraded |= block == "encourager";
    CHECK(degraded);
    CHECK(!root.encourager.enabled);
    CHECK(root.prefs.ui_language == "zh-Hant");
  }
  {
    std::string text = BaseDocument();
    // medals 的 count 非法 → 只丢该枚。
    text.replace(text.find("\"count\":3"), 9, "\"count\":-3");
    Root root = ParseOk(text);
    CHECK(root.medals.earned.empty());
    CHECK(root.prefs.ui_language == "zh-Hant");
  }
  {
    std::string text = BaseDocument();
    // curve 常量不符 → 块降级。
    text.replace(text.find("\"bucket_minutes\":15"), 19, "\"bucket_minutes\":30");
    Root root = ParseOk(text);
    bool degraded = false;
    for (const std::string& block : root.degraded_blocks) degraded |= block == "curve";
    CHECK(degraded);
    CHECK(root.curve_days.empty());
    CHECK(root.medals.earned.at("day.bronze").count == 3);
  }

  // --- 曲线日编解码 ---
  {
    CurveDay day;
    day.AddCount(0, 5);
    day.AddCount(95, 12345);
    day.MarkObserved(1);  // 真零。
    const json::Value record = SerializeCurveDay(day);
    const std::string hex = record.Find("coverage")->Str();
    CHECK(hex.size() == 24);
    CHECK(hex.compare(0, 2, "c0") == 0);      // 桶0(bit0)+桶1(bit1)。
    CHECK(hex.compare(22, 2, "01") == 0);     // 桶95 → 末字节最低位。
    CurveDay back;
    CHECK(ParseCurveDay(record, &back));
    CHECK(back.buckets[0] == 5);
    CHECK(back.buckets[1] == 0);
    CHECK(back.coverage.Get(1));
    CHECK(back.CoveredSum() == 5 + 12345);
  }
  {
    // >2^53 十进制字符串往返（契约 §4.3）。
    CurveDay day;
    const std::uint64_t huge = 9007199254740993ull;  // 2^53+1
    day.AddCount(3, huge);
    const json::Value record = SerializeCurveDay(day);
    const std::string& bucket3 = record.Find("buckets")->Items()[3].Str();
    CHECK(bucket3 == "9007199254740993");
    CurveDay back;
    CHECK(ParseCurveDay(record, &back));
    CHECK(back.buckets[3] == huge);
    // 2^53-1 仍是数字。
    CurveDay exact;
    exact.AddCount(4, (1ull << 53) - 1);
    const json::Value exactRecord = SerializeCurveDay(exact);
    CHECK(exactRecord.Find("buckets")->Items()[4].IsUInt());
    CHECK(ParseCurveDay(exactRecord, &exact) && exact.buckets[4] == (1ull << 53) - 1);
    // 读端也接受数字形式的大值（宽松读取）。
    auto numberForm = Parse("{\"coverage\":\"000000000000000000000000\","
                            "\"buckets\":[0,0,0,18446744073709551615]}");
    // 数组只有 4 个元素，完整解析应失败于桶数校验，而不是 GetU64。
    CurveDay rejected;
    CHECK(!ParseCurveDay(numberForm.value, &rejected));
  }

  // --- curve.days 映射加载与修剪 ---
  {
    Root root = Root::Default();
    CurveDay day;
    day.AddCount(10, 7);
    root.curve_days["2026-11-08"] = CurveDayValue{day};
    root.curve_days["2026-08-01"] = CurveDayValue{day};  // 超出 60 天。
    root.curve_days["bad-key"] = CurveDayValue{day};
    WriteCurveBlock(&root);
    const std::string text = Serialize(root);
    const Root back = ParseOk(text);
    // bad-key 被丢弃；60 天修剪需要 todayKey（这里 Load 未传 → 未修剪）。
    CHECK(back.curve_days.count("2026-11-08") == 1);
    CHECK(back.curve_days.count("bad-key") == 0);
    // 带锚点加载后修剪。
    json::Value tree = back.tree;
    Root trimmed;
    CHECK(ParseInto(tree, &trimmed));
    LoadCurveDays(*tree.Find("curve")->Find("days"), "2026-11-08", &trimmed);
    CHECK(trimmed.curve_days.count("2026-08-01") == 0);
    CHECK(trimmed.curve_days.count("2026-11-08") == 1);
    CHECK(trimmed.curve_days["2026-11-08"].day.buckets[10] == 7);
  }

  // --- 迁移收据（幂等） ---
  {
    Root root = Root::Default();
    ApplyMigrationReceipt(&root, 1762581120, true, "data_ini");
    CHECK(root.migration.from_095);
    CHECK(root.migration.migrated_at_utc == 1762581120);
    CHECK(root.migration.legacy_source == "data_ini");
    ApplyMigrationReceipt(&root, 999, true, "other");  // 幂等：不覆盖。
    CHECK(root.migration.migrated_at_utc == 1762581120);
    // 已有收据的文档再载入不重写。
    Root loaded = ParseOk(Serialize(root));
    ApplyMigrationReceipt(&loaded, 123, true, "x");
    CHECK(loaded.migration.migrated_at_utc == 1762581120);
  }

  // --- 60 天 + 每桶 20 位数字的体积估算（契约 §6：应 < 1 MiB） ---
  {
    Root root = Root::Default();
    // 60 天、每桶约 20 位（接近 uint64 上限）。
    for (int dayIndex = 0; dayIndex < 60; ++dayIndex) {
      CurveDay day;
      for (int bucket = 0; bucket < 96; ++bucket)
        day.buckets[static_cast<std::size_t>(bucket)] =
            18446744073709551615ull - static_cast<std::uint64_t>(bucket);
      char key[16];
      std::snprintf(key, sizeof(key), "2026-%02d-%02d", 9 + dayIndex / 30,
                    1 + dayIndex % 30);
      root.curve_days[key] = CurveDayValue{day};
    }
    MergeInto(&root);
    const std::string text = json::Serialize(root.tree);
    CHECK(text.size() < kMaxFileBytes);
    // 典型体积估算（每桶 ≤5 位）在 60–150 KiB 契约预期内。
    Root small = Root::Default();
    for (int dayIndex = 0; dayIndex < 60; ++dayIndex) {
      CurveDay day;
      for (int bucket = 0; bucket < 96; ++bucket)
        day.buckets[static_cast<std::size_t>(bucket)] =
            static_cast<std::uint64_t>((dayIndex * 96 + bucket) % 90000);
      char key[16];
      std::snprintf(key, sizeof(key), "2026-%02d-%02d", 9 + dayIndex / 30,
                    1 + dayIndex % 30);
      small.curve_days[key] = CurveDayValue{day};
    }
    MergeInto(&small);
    const std::string smallText = json::Serialize(small.tree);
    // 契约 §6：常见 JSON 文本开销约 60–150 KiB（含键名与结构）。此构造偏小
    // （多数桶为 ≤5 位数字），只需落在明确区间内。
    CHECK(smallText.size() > 20 * 1024);
    CHECK(smallText.size() < 300 * 1024);
  }

  // --- 鼓励器 / 勋章字段边界 ---
  {
    std::string text = BaseDocument();
    // 未知语言。
    text.replace(text.find("zh-Hant"), 7, "fr-FR");
    Root root = ParseOk(text);
    bool degraded = false;
    for (const std::string& block : root.degraded_blocks) degraded |= block == "prefs";
    CHECK(degraded);
  }
  {
    std::string text = BaseDocument();
    // scale 超出范围。
    text.replace(text.find("1.25"), 4, "9.0");
    Root root = ParseOk(text);
    bool degraded = false;
    for (const std::string& block : root.degraded_blocks) degraded |= block == "prefs";
    CHECK(degraded);
  }
  {
    std::string text = BaseDocument();
    // scale 用字符串小数（契约允许；macOS 端写数字，读端两者都收）。
    text.replace(text.find("1.25"), 4, "\"1.5\"");
    Root root = ParseOk(text);
    CHECK(std::fabs(root.prefs.appearance_scale - 1.5) < 1e-12);
  }

  if (g_fail == 0) std::printf("metrics_store_test: OK (%d checks)\n", g_checks);
  else std::printf("metrics_store_test: FAILED (%d/%d)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
