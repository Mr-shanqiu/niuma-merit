#pragma once

// 0.9.6 L2 · Windows 多语 UI 支持（zh-Hans / zh-Hant / ja / en）。
//
// 目标与 macOS 一致（CONTRACT_096 §10）：
//   - 语言归一化统一走 S0 的 niuma::reminder::LocaleFromLanguageTag：
//       ja* → 日语；en* → 英语；zh + Hant/-TW/-HK/-MO → 繁中；其余（含未知/空）→ 简中。
//   - UI 文案、内容语言（reminder catalog）与货币默认三处同一映射。
//
// Text(简中, English)：zh-Hans 取第一参数；en 取第二参数；
// zh-Hant / ja 查 ui_text_table.h（键 = 简中原文）；缺词条回落简中。
//
// 语言只解析一次：环境变量 NIUMA_UI_LANGUAGE（验收/测试用，接受同一套标签，
// 兼容旧值 zh/en）优先，否则取系统首选 UI 语言（GetUserPreferredUILanguages）。

#include <string>

namespace niuma::ui {

enum class Language {
  SimplifiedChinese = 0,
  TraditionalChinese = 1,
  Japanese = 2,
  English = 3,
  Korean = 4,
};

// 当前 UI 语言（进程内只解析一次）。
Language CurrentLanguage();

// 规范语言标签："zh-Hans" / "zh-Hant" / "ja" / "en"（CONTRACT_096 §10）。
const char* CurrentLanguageTag();

// 是否汉字圈（简中或繁中）；用于形象名等只有 zh/en 两版的回退选择。
bool IsChineseScript();

// 4 语查表：zh-Hans→zh，en→en，zh-Hant/ja→表；缺词条回落 zh。
// 返回值指向字符串字面量或静态表，进程生命周期内稳定。
const wchar_t* Text(const wchar_t* zhHans, const wchar_t* english);

}  // namespace niuma::ui
