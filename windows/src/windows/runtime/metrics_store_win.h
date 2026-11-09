#pragma once

// A1 · metrics-096.json 侧车 —— Windows 文件层（仅 MSVC/Win32 构建包含）。
//
// 契约（CONTRACT_096 §4.2 / §5.4 / §5.3）：
//   - 原子写：metrics-096.json.tmp → FlushFileBuffers → MoveFileExW(REPLACE)；
//     覆盖正式文件前先复制为 metrics-096.previous.json。
//   - 启动恢复：正式文件解析失败 → 尝试 previous → 仍失败则把正式文件改名为
//     metrics-096.corrupt-<epoch>.json 并重建空侧车；清理残留 .tmp。
//   - 块级降级：坏块只影响对应功能（ParseInto 已处理），错误写
//     metrics-096.errors.log（不含路径/个人信息）。
//   - 1 MiB 硬上限：先修剪最旧 curve 日；仍超限拒绝本次写入并保留旧文件。
//
// 写入语义：单线程调用方（UI owner）在批量落盘边界上调用 Load/Save，绝不在
// 输入回调内调用。Save 同步执行（文件小、有上限，且沿用 data.ini 的合并写入
// 边界节奏）；调用失败不抛异常，通过返回值与 diagnostics 观察。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include "../../client/core/metrics_store.h"

#include <cstdio>
#include <string>
#include <vector>

namespace niuma {
namespace metrics {
namespace win {

struct LoadOutcome {
  // true：root 可用（新文档或成功恢复/降级）。false：连目录都建不出来等致命情况。
  bool ok = false;
  bool fileExisted = false;
  bool usedPrevious = false;      // 从 previous 恢复
  bool renamedCorrupt = false;    // 正式文件已改名 corrupt-<epoch>
  std::vector<std::string> degradedBlocks;  // 本次读取降级的块
  DWORD error = ERROR_SUCCESS;    // 致命失败时的 Win32 错误码
};

class MetricsFileStore {
 public:
  // directory：侧车所在目录（= data.ini 同目录，含隔离验收根）。不创建目录。
  explicit MetricsFileStore(std::wstring directory) : directory_(std::move(directory)) {}

  // 幂等加载。若文件不存在则 root 保持默认值并标记 created。
  LoadOutcome Load(Root* root) {
    LoadOutcome outcome;
    if (!root) return outcome;
    EnsureDirectory();
    const std::wstring mainPath = MainPath();
    const bool mainExists = FileExists(mainPath);
    outcome.fileExisted = mainExists;
    if (mainExists) {
      std::string text;
      if (ReadFileUtf8(mainPath, &text)) {
        if (ApplyText(text, root, &outcome, directory_)) {
          outcome.ok = true;
          DeleteFileW(TmpPath().c_str());  // 崩溃残留 .tmp 清理。
          return outcome;
        }
      }
      // 正式文件不可用 → previous。
      std::string previousText;
      if (ReadFileUtf8(PreviousPath(), &previousText)) {
        LoadOutcome previousOutcome;
        if (ApplyText(previousText, root, &previousOutcome, directory_)) {
          outcome.ok = true;
          outcome.usedPrevious = true;
          outcome.degradedBlocks = std::move(previousOutcome.degradedBlocks);
          DeleteFileW(TmpPath().c_str());
          return outcome;
        }
      }
      // 仍失败：正式文件改名归档并重建空侧车（§5.4）。
      const std::wstring corrupt = CorruptPath();
      if (MoveFileExW(mainPath.c_str(), corrupt.c_str(),
                      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        outcome.renamedCorrupt = true;
        AppendErrorsLog("metrics main and previous unreadable; renamed to corrupt");
      } else {
        AppendErrorsLog("metrics main unreadable; rename to corrupt failed");
      }
      DeleteFileW(TmpPath().c_str());
    }
    *root = Root::Default();
    root->created = true;
    outcome.ok = true;
    return outcome;
  }

  // 序列化 + 上限修剪 + 原子落盘。返回 false 表示本次写入被拒绝（保留旧文件）。
  bool Save(Root* root) {
    if (!root) return false;
    EnsureDirectory();
    std::string text = Serialize(*root);
    if (text.empty()) return false;
    if (text.size() > kMaxFileBytes) {
      // 先逐日丢弃最旧 curve 日（只删桶），再重试一次；仍超限则拒绝本次写入
      // （不写坏旧文件）。
      PruneCurveDaysUntilFits(root, kMaxFileBytes);
      text = Serialize(*root);
      if (text.size() > kMaxFileBytes) {
        AppendErrorsLog("metrics payload exceeds 1 MiB after pruning; write rejected");
        return false;
      }
    }
    const std::wstring mainPath = MainPath();
    if (FileExists(mainPath)) {
      // 备份上一版本（旧 previous 直接覆盖）。
      CopyFileW(mainPath.c_str(), PreviousPath().c_str(), FALSE);
    }
    const std::wstring tmpPath = TmpPath();
    if (!WriteFileUtf8(tmpPath, text)) {
      AppendErrorsLog("metrics tmp write failed");
      return false;
    }
    if (!MoveFileExW(tmpPath.c_str(), mainPath.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      AppendErrorsLog("metrics atomic replace failed");
      DeleteFileW(tmpPath.c_str());
      return false;
    }
    return true;
  }

  const std::wstring& directory() const noexcept { return directory_; }
  std::wstring MainPath() const { return directory_ + L"\\metrics-096.json"; }
  std::wstring TmpPath() const { return directory_ + L"\\metrics-096.json.tmp"; }
  std::wstring PreviousPath() const {
    return directory_ + L"\\metrics-096.previous.json";
  }
  std::wstring CorruptPath() const {
    return directory_ + L"\\metrics-096.corrupt-" +
        std::to_wstring(static_cast<long long>(std::time(nullptr))) + L".json";
  }
  std::wstring ErrorsLogPath() const {
    return directory_ + L"\\metrics-096.errors.log";
  }

 private:
  static bool FileExists(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
        !(attributes & FILE_ATTRIBUTE_DIRECTORY);
  }

  void EnsureDirectory() {
    if (directory_.empty()) return;
    CreateDirectoryW(directory_.c_str(), nullptr);
  }

  // 应用一段 JSON 文本；schema/namespace 不符或解析失败返回 false（调用方走
  // previous/corrupt 恢复）；块级降级记录在 outcome 并写入 errors 日志。
  static bool ApplyText(const std::string& text, Root* root, LoadOutcome* outcome,
                        const std::wstring& logDirectory) {
    json::ParseLimits limits;
    limits.maxNodes = 200000;
    limits.maxDepth = 64;
    limits.maxStringBytes = 1u << 20;
    json::ParseResult parsed = json::Parse(text, limits);
    if (parsed.error != json::ParseError::None) return false;
    if (!ParseInto(parsed.value, root)) return false;
    outcome->degradedBlocks = root->degraded_blocks;
    if (!root->degraded_blocks.empty()) {
      std::string line = "metrics degraded blocks:";
      for (const std::string& block : root->degraded_blocks) {
        line += ' ';
        line += block;
      }
      MetricsFileStore logger(logDirectory);
      logger.AppendErrorsLog(line);
    }
    return true;
  }

  static bool ReadFileUtf8(const std::wstring& path, std::string* out) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 ||
        static_cast<std::uint64_t>(size.QuadPart) > kMaxFileBytes) {
      CloseHandle(file);
      return false;  // 超上限的文件按损坏处理，不做部分解析。
    }
    std::string text;
    text.resize(static_cast<std::size_t>(size.QuadPart));
    DWORD read = 0;
    const BOOL ok = text.empty() ||
        ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read, nullptr);
    CloseHandle(file);
    if (!ok || read != text.size()) return false;
    *out = std::move(text);
    return true;
  }

  static bool WriteFileUtf8(const std::wstring& path, const std::string& text) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL ok = text.empty() ||
        WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
                  nullptr);
    if (ok && written == text.size()) FlushFileBuffers(file);
    const bool success = ok && written == text.size();
    CloseHandle(file);
    if (!success) DeleteFileW(path.c_str());
    return success;
  }

  void AppendErrorsLog(const std::string& line) const {
    if (directory_.empty()) return;
    HANDLE file = CreateFileW(ErrorsLogPath().c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    // 时间戳（UTC 秒）+ 行。不含路径、不含个人信息。
    char stamped[160];
    const int length = std::snprintf(stamped, sizeof(stamped), "%lld %s\n",
        static_cast<long long>(std::time(nullptr)), line.c_str());
    if (length > 0) {
      DWORD written = 0;
      WriteFile(file, stamped, static_cast<DWORD>(length), &written, nullptr);
    }
    CloseHandle(file);
  }

  // 逐日丢弃最旧 curve 日，直到序列化结果回到上限内或 curve 已空。
  // 只删 curve.days 条目；其他块与旧 [daily] 日总数不受影响。
  static void PruneCurveDaysUntilFits(Root* root, std::size_t maxBytes) {
    while (root->curve_days.size() > 1) {
      root->curve_days.erase(root->curve_days.begin());
      if (Serialize(*root).size() <= maxBytes) return;
    }
    root->curve_days.clear();
  }

  std::wstring directory_;
};

}  // namespace win
}  // namespace metrics
}  // namespace niuma
