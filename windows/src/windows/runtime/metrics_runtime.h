#pragma once

// F4 · 曲线桶采集落盘（app 侧胶水）。
//
// 职责：
//   - 持有 metrics-096.json 的强类型 Root（由 MetricsFileStore 加载/保存）。
//   - 把输入线程 ledger 里的 curve 环（CurveDayRecord，LocalDate）合并进
//     root.curve_days（date-key -> CurveDay），批量落盘。
//   - 60 天滚删仅在 flush 前对 curve.days 生效（只删桶，不动旧 [daily]）。
//
// 约束（CONTRACT §5.4）：文件 I/O 只在 UI owner 的批量落盘边界发生，绝不在
// 输入回调或渲染路径里。本类不参与主 widget 渲染。

#include "../../client/core/input_state.h"
#include "../../client/core/metrics_store.h"
#include "metrics_store_win.h"

#include <cstdint>
#include <string>
#include <vector>

namespace niuma::windows::runtime {

class MetricsRuntime {
 public:
  // 加载侧车（目录 = data.ini 同目录）。失败只降级新功能，不阻止启动。
  bool Load(const std::wstring& directory, std::int64_t nowUtc);

  // 把 ledger 提供的近期曲线日合并进文档；只取代覆盖/非零的日。
  void ApplyCurve(const std::vector<client::core::CurveDayRecord>& records);

  // 批量落盘：先按 todayKey 做 60 天滚删，再原子写。无脏数据时不写。
  // 返回 false 表示本次写入被拒绝/失败（保留旧文件），下次可重试。
  bool Flush(const std::string& todayKey);

  bool loaded() const noexcept { return loaded_; }
  bool dirty() const noexcept { return dirty_; }
  std::size_t curve_days() const noexcept { return root_.curve_days.size(); }
  const DWORD lastError() const noexcept { return lastError_; }
  const niuma::metrics::Root& root() const noexcept { return root_; }

 private:
  niuma::metrics::win::MetricsFileStore store_{std::wstring()};
  niuma::metrics::Root root_{};
  bool loaded_ = false;
  bool dirty_ = false;
  DWORD lastError_ = ERROR_SUCCESS;
};

}  // namespace niuma::windows::runtime
