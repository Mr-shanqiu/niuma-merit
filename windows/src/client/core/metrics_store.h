#pragma once

// A1 · 0.9.6 本地侧车 metrics-096.json —— 平台无关文档层（CONTRACT_096 §1/§4.2/§5）。
//
// 职责边界：
//   - 本头文件只做「文档」：根结构（schema_version/namespace/migration/prefs/
//     encourager/medals/curve）的默认值、按块解析降级、曲线块与 CurveDay 的
//     编解码、1 MiB 上限修剪、迁移收据。不接触文件系统、不知道路径。
//   - 文件原子性（tmp → fsync → rename、previous 备份、corrupt 归档、errors
//     日志）由平台胶水 `metrics_store_win.h`（仅 MSVC 构建包含）完成。
//   - JSON 编解码由 `metrics_json.h` 完成；本层在其上做语义校验。未知字段
//     保留：解析块时保留块内未知键，写回时合并（§1.1）。
//
// 所有 0.9.6 新增本地数据都进这份侧车；旧 data.ini 只读兼容（§4.1）。

#include "../../client/core/merit_curve.h"
#include "../../client/core/metrics_json.h"

#include <cmath>
#include <cstdint>
#include <ctime>
#include <limits>
#include <map>
#include <string>
#include <vector>

namespace niuma {
namespace metrics {

inline constexpr const char* kNamespace = "niuma.gongde.v096";
inline constexpr std::int64_t kSchemaVersion = 1;
inline constexpr const char* kAppVersion = "0.9.6";
inline constexpr const char* kThresholdsVersion = "builtin-2026-11-08";
// 契约 §6：单文件硬上限。侧车超限时先修剪最旧 curve 日，再超限则拒绝本次写入。
inline constexpr std::size_t kMaxFileBytes = 1024 * 1024;

// ---- 每块强类型视图（业务代码使用；原始树在 Root 内） ----

struct Prefs {
  std::string ui_language = "zh-Hans";
  double appearance_scale = 1.0;
};

struct Encourager {
  bool enabled = false;
  std::uint64_t daily_wage_minor = 0;
  std::string currency = "CNY";
  bool currency_override = false;
  int start_minute = 540;
  int end_minute = 1080;

  bool ValidWindow() const noexcept {
    return start_minute >= 0 && start_minute < end_minute && end_minute <= 1440;
  }
};

struct MedalEarned {
  std::string first_earned_day;  // YYYY-MM-DD，可为空（兼容旧记录）。
  std::uint32_t count = 0;
  // 上次计数的自然周期键（"YYYY-MM-DD" / "YYYY-Www" 起点日 / "YYYY-MM"）。
  // 新增字段（§1.1 允许）：跨重启去重同一周期，避免重复计次。
  std::string last_period;
  bool lit = false;  // count>0 或 first_earned_day 非空（读侧推导）。
};

struct Medals {
  std::string thresholds_version = kThresholdsVersion;
  std::map<std::string, MedalEarned> earned;
};

struct Migration {
  bool from_095 = false;
  std::int64_t migrated_at_utc = 0;
  std::string legacy_source;  // "data_ini"；空表示无迁移收据。
  std::int64_t reconcile_at_utc = 0;  // §5.6 对账收据，0 表示未对账。
  // §12.1 历史勋章静默补授的一次性守门（先置位再补授，防止重放重复计次）。
  bool medals_backfilled = false;
};

struct CurveDayValue {
  curve::CurveDay day;
};

// 根文档。`tree` 是权威序列化源（含未知字段的保留），typed 视图是从树同步出的
// 只读快照；修改流程 = 改视图 → MergeXxx 写回树 → Serialize。
struct Root {
  json::Value tree = DefaultTree();
  Prefs prefs;
  Encourager encourager;
  Medals medals;
  Migration migration;
  // curve.days 的强类型缓存；键为本地日 "YYYY-MM-DD"。仅承载 0.9.6 采集到的日。
  std::map<std::string, CurveDayValue> curve_days;
  // 诊断：最近一次 Load 的降级情况（用于 errors 日志与验收）。
  bool created = false;
  bool recovered_from_previous = false;
  bool rebuilt_corrupt = false;
  std::vector<std::string> degraded_blocks;

  static json::Value DefaultTree();
  static Root Default();
};

// ---- 树 <-> 类型视图 ----

// 从 `tree` 解析各块：坏块回默认并记录到 degraded_blocks；schema/namespace 不符
// 返回 false（调用方走 previous/corrupt 恢复）。curve 块按 §4.3 逐日解码。
bool ParseInto(const json::Value& tree, Root* out);

// 把类型视图写回 `tree`（保留树中未识别的键）。curve 以 `curve_days` 为准整体
// 重写 `curve.days`（60 天窗口内的完整日）。
// 把类型视图写回 `tree`（保留树中未识别的键）。curve 以 `curve_days` 为准整体
// 重写 `curve.days`（60 天窗口内的完整日）。
void MergeInto(Root* root);

// 序列化；内部先 MergeInto（保留未知字段），再输出紧凑 JSON 文本。
// 调用后根树为最新合并结果（重复调用幂等；updated_at_utc 刷新为当前时间）。
std::string Serialize(Root& root);

// ---- 曲线块编解码（§4.3） ----

// 解析单个 curve day 记录；任一字段非法返回 false。
bool ParseCurveDay(const json::Value& record, curve::CurveDay* out);

// 写出单个 curve day：coverage=24 hex；桶 ≤2^53 写数字，否则写十进制字符串。
json::Value SerializeCurveDay(const curve::CurveDay& day);

// 载入曲线天映射（含键合法性检查、坏日丢弃、修剪到保留窗口）。
void LoadCurveDays(const json::Value& daysObject, const std::string& todayKey,
                   Root* out);

// 用强类型映射整体重写 curve 块（含常量字段）。
void WriteCurveBlock(Root* root);

// 60 天滚删（仅删 curve.days 桶条目，不动其他块/旧日总数）。
void PruneCurveDays(Root* root, const std::string& todayKey);

// 迁移收据（§5.1/§5.6）：首次创建置 from_095=true + legacy_source；幂等。
void ApplyMigrationReceipt(Root* root, std::int64_t nowUtc, bool created,
                           const char* legacySource);

// ---- 实现 ----

namespace detail {

inline json::Value MakeDefaultsEncourager() {
  json::Value block = json::Value::MakeObject({});
  block.Set("enabled", json::Value::MakeBool(false));
  block.Set("daily_wage_minor", json::Value::MakeUInt(0));
  block.Set("currency", json::Value::MakeString("CNY"));
  block.Set("currency_override", json::Value::MakeBool(false));
  block.Set("start_minute", json::Value::MakeInt(540));
  block.Set("end_minute", json::Value::MakeInt(1080));
  return block;
}

inline json::Value MakeDefaultsMedals() {
  json::Value block = json::Value::MakeObject({});
  block.Set("thresholds_version", json::Value::MakeString(kThresholdsVersion));
  block.Set("earned", json::Value::MakeObject({}));
  return block;
}

inline json::Value MakeDefaultsCurve() {
  json::Value block = json::Value::MakeObject({});
  block.Set("bucket_minutes", json::Value::MakeInt(curve::kBucketMinutes));
  block.Set("buckets_per_day", json::Value::MakeInt(curve::kBucketsPerDay));
  block.Set("retention_days", json::Value::MakeInt(curve::kRetentionDays));
  block.Set("days", json::Value::MakeObject({}));
  return block;
}

inline json::Value MakeDefaultsPrefs() {
  json::Value block = json::Value::MakeObject({});
  block.Set("ui_language", json::Value::MakeString("zh-Hans"));
  block.Set("appearance_scale", json::Value::MakeDouble(1.0));
  return block;
}

// 类型视图 -> tree 的合并（保留未知键）。
inline void MergePrefs(Root* root) {
  json::Value block = json::Value::MakeObject({});
  const json::Value* existing = root->tree.Find("prefs");
  if (existing && existing->IsObject()) block = *existing;
  block.Set("ui_language", json::Value::MakeString(root->prefs.ui_language));
  block.Set("appearance_scale",
            json::Value::MakeDouble(root->prefs.appearance_scale));
  root->tree.Set("prefs", std::move(block));
}

inline void MergeEncourager(Root* root) {
  json::Value block = json::Value::MakeObject({});
  const json::Value* existing = root->tree.Find("encourager");
  if (existing && existing->IsObject()) block = *existing;
  block.Set("enabled", json::Value::MakeBool(root->encourager.enabled));
  block.Set("daily_wage_minor",
            json::Value::MakeUInt(root->encourager.daily_wage_minor));
  block.Set("currency", json::Value::MakeString(root->encourager.currency));
  block.Set("currency_override",
            json::Value::MakeBool(root->encourager.currency_override));
  block.Set("start_minute", json::Value::MakeInt(root->encourager.start_minute));
  block.Set("end_minute", json::Value::MakeInt(root->encourager.end_minute));
  root->tree.Set("encourager", std::move(block));
}

inline void MergeMedals(Root* root) {
  json::Value block = json::Value::MakeObject({});
  const json::Value* existing = root->tree.Find("medals");
  if (existing && existing->IsObject()) block = *existing;
  block.Set("thresholds_version",
            json::Value::MakeString(root->medals.thresholds_version));
  json::Value earned = json::Value::MakeObject({});
  for (const auto& entry : root->medals.earned) {
    json::Value record = json::Value::MakeObject({});
    record.Set("first_earned_day",
               json::Value::MakeString(entry.second.first_earned_day));
    record.Set("count", json::Value::MakeUInt(entry.second.count));
    if (!entry.second.last_period.empty())
      record.Set("last_period", json::Value::MakeString(entry.second.last_period));
    earned.Set(entry.first, std::move(record));
  }
  block.Set("earned", std::move(earned));
  root->tree.Set("medals", std::move(block));
}

inline void MergeMigration(Root* root) {
  json::Value block = json::Value::MakeObject({});
  const json::Value* existing = root->tree.Find("migration");
  if (existing && existing->IsObject()) block = *existing;
  block.Set("from_095", json::Value::MakeBool(root->migration.from_095));
  block.Set("migrated_at_utc",
            json::Value::MakeInt(root->migration.migrated_at_utc));
  block.Set("legacy_source",
            json::Value::MakeString(root->migration.legacy_source));
  if (root->migration.reconcile_at_utc > 0)
    block.Set("reconcile_at_utc",
              json::Value::MakeInt(root->migration.reconcile_at_utc));
  if (root->migration.medals_backfilled)
    block.Set("medals_backfilled", json::Value::MakeBool(true));
  root->tree.Set("migration", std::move(block));
}

}  // namespace detail

inline json::Value Root::DefaultTree() {
  json::Value tree = json::Value::MakeObject({});
  tree.Set("schema_version", json::Value::MakeInt(kSchemaVersion));
  tree.Set("namespace", json::Value::MakeString(kNamespace));
  tree.Set("app_version", json::Value::MakeString(kAppVersion));
  tree.Set("updated_at_utc", json::Value::MakeInt(0));
  tree.Set("migration", json::Value::MakeObject({}));
  tree.Set("prefs", detail::MakeDefaultsPrefs());
  tree.Set("encourager", detail::MakeDefaultsEncourager());
  tree.Set("medals", detail::MakeDefaultsMedals());
  tree.Set("curve", detail::MakeDefaultsCurve());
  return tree;
}

inline Root Root::Default() {
  Root root;
  root.tree = Root::DefaultTree();
  return root;
}

inline bool ParseCurveDay(const json::Value& record, curve::CurveDay* out) {
  if (!out || !record.IsObject()) return false;
  const json::Value* coverage = record.Find("coverage");
  const json::Value* buckets = record.Find("buckets");
  if (!coverage || !coverage->IsString() || !buckets || !buckets->IsArray()) return false;
  if (buckets->Items().size() != static_cast<std::size_t>(curve::kBucketsPerDay))
    return false;
  curve::Coverage parsedCoverage;
  if (!curve::Coverage::FromHex(coverage->Str(), &parsedCoverage)) return false;
  curve::CurveDay day;
  day.coverage = parsedCoverage;
  for (int i = 0; i < curve::kBucketsPerDay; ++i) {
    const json::Value& value = buckets->Items()[static_cast<std::size_t>(i)];
    // 契约 §4.3：读取端须同时接受 JSON 数字与十进制字符串（>2^53）。
    std::uint64_t parsed = 0;
    if (!json::GetU64(value, &parsed)) return false;
    day.buckets[static_cast<std::size_t>(i)] = parsed;
  }
  *out = day;
  return true;
}

inline json::Value SerializeCurveDay(const curve::CurveDay& day) {
  json::Value buckets = json::Value::MakeArray({});
  buckets.Items().reserve(static_cast<std::size_t>(curve::kBucketsPerDay));
  for (int i = 0; i < curve::kBucketsPerDay; ++i) {
    const std::uint64_t value = day.buckets[static_cast<std::size_t>(i)];
    // 契约 §4.3：JSON number 精确到 2^53；更大的 64 位值用十进制字符串无损表示。
    constexpr std::uint64_t kMaxExact = 1ull << 53;
    if (value < kMaxExact) buckets.Items().push_back(json::Value::MakeUInt(value));
    else buckets.Items().push_back(json::Value::MakeString(std::to_string(value)));
  }
  json::Value record = json::Value::MakeObject({});
  record.Set("coverage", json::Value::MakeString(day.coverage.ToHex()));
  record.Set("buckets", std::move(buckets));
  return record;
}

inline void LoadCurveDays(const json::Value& daysObject,
                          const std::string& todayKey, Root* out) {
  out->curve_days.clear();
  if (!daysObject.IsObject()) return;
  for (const auto& entry : daysObject.Members()) {
    curve::CurveDay day;
    if (!ParseCurveDay(entry.second, &day)) continue;  // 坏日只丢该日。
    int y = 0, m = 0, d = 0;
    if (!curve::ParseDateKey(entry.first, &y, &m, &d)) continue;
    out->curve_days[entry.first] = CurveDayValue{day};
  }
  PruneCurveDays(out, todayKey);
}

inline void WriteCurveBlock(Root* root) {
  json::Value block = json::Value::MakeObject({});
  const json::Value* existing = root->tree.Find("curve");
  if (existing && existing->IsObject()) block = *existing;
  block.Set("bucket_minutes", json::Value::MakeInt(curve::kBucketMinutes));
  block.Set("buckets_per_day", json::Value::MakeInt(curve::kBucketsPerDay));
  block.Set("retention_days", json::Value::MakeInt(curve::kRetentionDays));
  json::Value days = json::Value::MakeObject({});
  for (const auto& entry : root->curve_days)
    days.Set(entry.first, SerializeCurveDay(entry.second.day));
  block.Set("days", std::move(days));
  root->tree.Set("curve", std::move(block));
}

inline void PruneCurveDays(Root* root, const std::string& todayKey) {
  if (root->curve_days.empty()) return;
  std::vector<std::string> keys;
  keys.reserve(root->curve_days.size());
  for (const auto& entry : root->curve_days) keys.push_back(entry.first);
  for (const std::string& key : curve::KeysToPrune(keys, todayKey, curve::kRetentionDays))
    root->curve_days.erase(key);
}

inline void ApplyMigrationReceipt(Root* root, std::int64_t nowUtc, bool created,
                                  const char* legacySource) {
  if (!created || root->migration.from_095) return;
  root->migration.from_095 = true;
  root->migration.migrated_at_utc = nowUtc;
  root->migration.legacy_source = legacySource ? legacySource : "";
}

namespace detail {

inline bool ParsePrefs(const json::Value& block, Root* out) {
  if (!block.IsObject()) return false;
  Prefs prefs;
  const json::Value* language = block.Find("ui_language");
  if (!language || !language->IsString()) return false;
  static const char* kAllowed[] = {"zh-Hans", "zh-Hant", "ja", "en"};
  bool allowed = false;
  for (const char* candidate : kAllowed)
    if (language->Str() == candidate) allowed = true;
  if (!allowed) return false;
  prefs.ui_language = language->Str();
  const json::Value* scale = block.Find("appearance_scale");
  if (!scale) return false;
  if (!json::GetDouble(*scale, &prefs.appearance_scale)) return false;
  if (!(prefs.appearance_scale >= 0.6 && prefs.appearance_scale <= 1.8))
    return false;
  out->prefs = prefs;
  return true;
}

inline bool ParseEncourager(const json::Value& block, Root* out) {
  if (!block.IsObject()) return false;
  Encourager encourager;
  const json::Value* enabled = block.Find("enabled");
  const json::Value* wage = block.Find("daily_wage_minor");
  const json::Value* currency = block.Find("currency");
  const json::Value* overrideFlag = block.Find("currency_override");
  const json::Value* start = block.Find("start_minute");
  const json::Value* end = block.Find("end_minute");
  if (!enabled || !enabled->IsBool()) return false;
  if (!wage || !json::GetU64(*wage, &encourager.daily_wage_minor)) return false;
  if (!currency || !currency->IsString() || currency->Str().empty() ||
      currency->Str().size() > 8)
    return false;
  encourager.currency = currency->Str();
  if (!overrideFlag || !overrideFlag->IsBool()) return false;
  // JSON 非负整数统一存 UInt（metrics_json）；负数才是 Int。
  if (!start || !start->IsNumber() || start->Number() != std::floor(start->Number()) ||
      !end || !end->IsNumber() || end->Number() != std::floor(end->Number()))
    return false;
  const std::int64_t startValue = start->Int();
  const std::int64_t endValue = end->Int();
  if (startValue < 0 || endValue < 0 ||
      startValue > std::numeric_limits<int>::max() ||
      endValue > std::numeric_limits<int>::max())
    return false;
  encourager.start_minute = static_cast<int>(startValue);
  encourager.end_minute = static_cast<int>(endValue);
  if (!encourager.ValidWindow() || encourager.end_minute > 1440) return false;
  encourager.enabled = enabled->Bool();
  encourager.currency_override = overrideFlag->Bool();
  out->encourager = encourager;
  return true;
}

inline bool ParseMedals(const json::Value& block, Root* out) {
  if (!block.IsObject()) return false;
  const json::Value* thresholds = block.Find("thresholds_version");
  const json::Value* earned = block.Find("earned");
  if (!thresholds || !thresholds->IsString() || thresholds->Str().empty()) return false;
  if (!earned || !earned->IsObject()) return false;
  Medals medals;
  medals.thresholds_version = thresholds->Str();
  for (const auto& entry : earned->Members()) {
    if (!entry.second.IsObject()) continue;  // 坏记录只丢该枚，不否决整块。
    const json::Value* first = entry.second.Find("first_earned_day");
    const json::Value* count = entry.second.Find("count");
    std::uint64_t parsedCount = 0;
    // count 必须存在且为合法非负整数；非法记录只丢该枚。
    if (!count || !json::GetU64(*count, &parsedCount)) continue;
    if (parsedCount > 0xffffffffull) continue;
    MedalEarned record;
    record.count = static_cast<std::uint32_t>(parsedCount);
    if (first) {
      if (!first->IsString()) continue;
      int y = 0, m = 0, d = 0;
      if (!first->Str().empty() && !curve::ParseDateKey(first->Str(), &y, &m, &d))
        continue;
      record.first_earned_day = first->Str();
    }
    if (const json::Value* last = entry.second.Find("last_period"))
      if (last->IsString() && last->Str().size() <= 32) record.last_period = last->Str();
    record.lit = record.count > 0 || !record.first_earned_day.empty();
    medals.earned[entry.first] = record;
  }
  out->medals = medals;
  return true;
}

}  // namespace detail

inline bool ParseInto(const json::Value& tree, Root* out) {
  if (!out) return false;
  const json::Value* schema = tree.Find("schema_version");
  const json::Value* ns = tree.Find("namespace");
  if (!schema || !schema->IsNumber() ||
      schema->Number() != static_cast<double>(kSchemaVersion))
    return false;
  if (!ns || !ns->IsString() || ns->Str() != kNamespace) return false;
  *out = Root::Default();
  out->tree = tree;
  out->created = false;

  // 按块独立降级（§5.3）：坏块回默认值，其余块照常。
  if (const json::Value* block = tree.Find("prefs")) {
    if (!detail::ParsePrefs(*block, out)) {
      out->prefs = Prefs{};
      out->degraded_blocks.push_back("prefs");
      out->tree.Set("prefs", detail::MakeDefaultsPrefs());
    }
  } else out->degraded_blocks.push_back("prefs");
  if (const json::Value* block = tree.Find("encourager")) {
    if (!detail::ParseEncourager(*block, out)) {
      out->encourager = Encourager{};
      out->degraded_blocks.push_back("encourager");
      out->tree.Set("encourager", detail::MakeDefaultsEncourager());
    }
  } else out->degraded_blocks.push_back("encourager");
  if (const json::Value* block = tree.Find("medals")) {
    if (!detail::ParseMedals(*block, out)) {
      out->medals = Medals{};
      out->degraded_blocks.push_back("medals");
      out->tree.Set("medals", detail::MakeDefaultsMedals());
    }
  } else out->degraded_blocks.push_back("medals");
  if (const json::Value* block = tree.Find("curve")) {
    const json::Value* days = block->Find("days");
    const json::Value* bucketMinutes = block->Find("bucket_minutes");
    const json::Value* perDay = block->Find("buckets_per_day");
    const json::Value* retention = block->Find("retention_days");
    const bool constants = bucketMinutes &&
        bucketMinutes->Number() == static_cast<double>(curve::kBucketMinutes) &&
        perDay && perDay->Number() == static_cast<double>(curve::kBucketsPerDay) &&
        retention && retention->Number() == static_cast<double>(curve::kRetentionDays);
    if (!block->IsObject() || !days || !days->IsObject() || !constants) {
      out->curve_days.clear();
      out->degraded_blocks.push_back("curve");
      out->tree.Set("curve", detail::MakeDefaultsCurve());
    } else {
      LoadCurveDays(*days, std::string(), out);  // todayKey 空则不修剪。
    }
  } else out->degraded_blocks.push_back("curve");

  // migration 块宽松解析（缺失/坏块只影响收据）。JSON 非负整数统一为 UInt。
  if (const json::Value* block = tree.Find("migration")) {
    if (block->IsObject()) {
      if (const json::Value* flag = block->Find("from_095"))
        out->migration.from_095 = flag->IsBool() && flag->Bool();
      if (const json::Value* at = block->Find("migrated_at_utc"))
        if (at->IsNumber() && at->Number() >= 0 &&
            at->Number() == std::floor(at->Number()))
          out->migration.migrated_at_utc = at->Int();
      if (const json::Value* source = block->Find("legacy_source"))
        if (source->IsString()) out->migration.legacy_source = source->Str();
      if (const json::Value* reconcile = block->Find("reconcile_at_utc"))
        if (reconcile->IsNumber() && reconcile->Number() >= 0 &&
            reconcile->Number() == std::floor(reconcile->Number()))
          out->migration.reconcile_at_utc = reconcile->Int();
      if (const json::Value* backfilled = block->Find("medals_backfilled"))
        out->migration.medals_backfilled =
            backfilled->IsBool() && backfilled->Bool();
    }
  }
  return true;
}

inline void MergeInto(Root* root) {
  if (!root) return;
  detail::MergePrefs(root);
  detail::MergeEncourager(root);
  detail::MergeMedals(root);
  detail::MergeMigration(root);
  WriteCurveBlock(root);
  root->tree.Set("schema_version", json::Value::MakeInt(kSchemaVersion));
  root->tree.Set("namespace", json::Value::MakeString(kNamespace));
  root->tree.Set("app_version", json::Value::MakeString(kAppVersion));
}

// 序列化；内部先 MergeInto（保留未知字段），再输出紧凑 JSON 文本。
inline std::string Serialize(Root& root) {
  MergeInto(&root);
  root.tree.Set("updated_at_utc",
                json::Value::MakeInt(static_cast<std::int64_t>(std::time(nullptr))));
  return json::Serialize(root.tree);
}

}  // namespace metrics
}  // namespace niuma
