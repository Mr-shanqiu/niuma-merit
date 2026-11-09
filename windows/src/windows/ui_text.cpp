// 0.9.6 L2 · Windows 多语 UI 支持实现。见 ui_text.h。

#include "ui_text.h"

#include <windows.h>

#include <unordered_map>
#include <utility>

#include "../reminder_policy.h"
#include "ui_text_table.h"

namespace niuma::ui {
namespace {

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int length = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                         static_cast<int>(wide.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) return std::string();
  std::string out(static_cast<std::size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      out.data(), length, nullptr, nullptr);
  return out;
}

Language LanguageFromTag(const std::wstring& tag) {
  switch (niuma::reminder::LocaleFromLanguageTag(Utf8FromWide(tag).c_str())) {
    case niuma::reminder::Locale::ChineseTraditional: return Language::TraditionalChinese;
    case niuma::reminder::Locale::Japanese: return Language::Japanese;
    case niuma::reminder::Locale::English: return Language::English;
    case niuma::reminder::Locale::Chinese: break;
  }
  return Language::SimplifiedChinese;
}

// 环境变量覆盖（验收/测试）：接受与系统语言相同的 BCP-47 标签，兼容 "zh"/"en"。
std::wstring EnvironmentOverride() {
  const DWORD length = GetEnvironmentVariableW(L"NIUMA_UI_LANGUAGE", nullptr, 0);
  if (length == 0) return std::wstring();
  std::wstring buffer(static_cast<std::size_t>(length), L'\0');
  const DWORD written =
      GetEnvironmentVariableW(L"NIUMA_UI_LANGUAGE", buffer.data(), length);
  if (written == 0 || written >= length) return std::wstring();
  buffer.resize(static_cast<std::size_t>(written));
  return buffer;
}

// 系统首选 UI 语言（第一个），例如 "zh-Hant-TW"、"ja-JP"、"en-US"。
std::wstring SystemPreferredLanguage() {
  ULONG count = 0;
  ULONG size = 0;
  if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &size) ||
      size == 0) {
    return std::wstring();
  }
  std::wstring buffer(static_cast<std::size_t>(size), L'\0');
  if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, buffer.data(), &size)) {
    return std::wstring();
  }
  // 该 API 返回以 NUL 分隔的双重结尾列表；取第一个条目。
  const std::size_t end = buffer.find(L'\0');
  return buffer.substr(0, end == std::wstring::npos ? buffer.size() : end);
}

Language ResolveLanguage() {
  const std::wstring override = EnvironmentOverride();
  return LanguageFromTag(override.empty() ? SystemPreferredLanguage() : override);
}

struct Entry {
  std::wstring zhHant;
  std::wstring ja;
};

const std::unordered_map<std::wstring, Entry>& LookupTable() {
  static const std::unordered_map<std::wstring, Entry> table = [] {
    std::unordered_map<std::wstring, Entry> map;
    map.reserve(kNMUiTextEntryCountW);
    for (std::size_t index = 0; index < kNMUiTextEntryCountW; ++index) {
      const NMUiTextEntryW& entry = kNMUiTextEntriesW[index];
      map.emplace(std::wstring(entry.zhHans), Entry{entry.zhHant, entry.ja});
    }
    return map;
  }();
  return table;
}

}  // namespace

Language CurrentLanguage() {
  static const Language language = ResolveLanguage();
  return language;
}

const char* CurrentLanguageTag() {
  switch (CurrentLanguage()) {
    case Language::TraditionalChinese: return "zh-Hant";
    case Language::Japanese: return "ja";
    case Language::English: return "en";
    case Language::SimplifiedChinese: break;
  }
  return "zh-Hans";
}

bool IsChineseScript() {
  const Language language = CurrentLanguage();
  return language == Language::SimplifiedChinese ||
         language == Language::TraditionalChinese;
}

const wchar_t* Text(const wchar_t* zhHans, const wchar_t* english) {
  switch (CurrentLanguage()) {
    case Language::English: return english;
    case Language::TraditionalChinese:
    case Language::Japanese: {
      const auto& table = LookupTable();
      const auto found = table.find(std::wstring(zhHans));
      if (found == table.end()) return zhHans;
      return CurrentLanguage() == Language::TraditionalChinese
                 ? found->second.zhHant.c_str()
                 : found->second.ja.c_str();
    }
    case Language::SimplifiedChinese: break;
  }
  return zhHans;
}

}  // namespace niuma::ui
