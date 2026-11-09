#include "metrics_runtime.h"

#include <utility>

namespace niuma::windows::runtime {

namespace {

// LocalDate (YYYYMMDD uint32) -> "YYYY-MM-DD". Returns empty on invalid.
std::string DateKeyFromLocalDate(client::core::LocalDate date) {
  if (!client::core::InputCore::ValidDate(date)) return {};
  const int y = static_cast<int>(date / 10000);
  const int m = static_cast<int>((date / 100) % 100);
  const int d = static_cast<int>(date % 100);
  return niuma::curve::FormatDateKey(y, m, d);
}

bool DayHasData(const niuma::curve::CurveDay& day) {
  return day.coverage.CountSet() > 0 || day.CoveredSum() > 0;
}

}  // namespace

bool MetricsRuntime::Load(const std::wstring& directory, std::int64_t nowUtc) {
  store_ = niuma::metrics::win::MetricsFileStore(directory);
  const auto outcome = store_.Load(&root_);
  loaded_ = outcome.ok;
  lastError_ = outcome.ok ? ERROR_SUCCESS : outcome.error;
  if (!loaded_) return false;
  // 首次创建：写迁移收据（from_095=true, legacy_source=data_ini，§5.1）。
  if (root_.created) {
    niuma::metrics::ApplyMigrationReceipt(&root_, nowUtc, true, "data_ini");
    dirty_ = true;
  }
  return true;
}

void MetricsRuntime::ApplyCurve(
    const std::vector<client::core::CurveDayRecord>& records) {
  if (!loaded_) return;
  bool changed = false;
  for (const auto& record : records) {
    const std::string key = DateKeyFromLocalDate(record.date);
    if (key.empty() || !DayHasData(record.day)) continue;
    auto it = root_.curve_days.find(key);
    if (it == root_.curve_days.end()) {
      root_.curve_days.emplace(key, niuma::metrics::CurveDayValue{record.day});
      changed = true;
    } else if (it->second.day.coverage.ToHex() != record.day.coverage.ToHex()) {
      // 覆盖位图变化（新增采集桶/心跳）→ 采纳；桶计数只增不减，直接覆盖为
      // 输入的权威快照即可（输入线程是唯一计数 owner）。
      it->second.day = record.day;
      changed = true;
    } else {
      // 覆盖相同但桶可能增加；比较计数和。
      if (it->second.day.CoveredSum() != record.day.CoveredSum()) {
        it->second.day = record.day;
        changed = true;
      }
    }
  }
  if (changed) dirty_ = true;
}

bool MetricsRuntime::Flush(const std::string& todayKey) {
  if (!loaded_) return false;
  if (!dirty_) return true;
  // 先按 60 天窗口滚删 curve.days（只删桶）。
  niuma::metrics::PruneCurveDays(&root_, todayKey);
  if (!store_.Save(&root_)) {
    // 保留 dirty_，下次重试；不写坏旧文件。
    lastError_ = ERROR_WRITE_FAULT;
    return false;
  }
  dirty_ = false;
  lastError_ = ERROR_SUCCESS;
  return true;
}

}  // namespace niuma::windows::runtime
