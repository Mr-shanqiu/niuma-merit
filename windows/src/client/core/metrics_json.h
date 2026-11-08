#pragma once

// A1 · 侧车专用最小 JSON 解析器/写出器（仅标准 C++，无平台依赖）。
//
// 为什么不复用 `reminder_catalog_update.h` 的 JsonParser（CONTRACT_096 §13.3）：
// 那个解析器只接受 int64 整数、拒绝 `1.0` 这类小数，会把合法侧车判坏。本解析器
// 为 metrics-096.json 定制，只服务侧车读写：
//   - 读：完整 JSON 数字语法（整数、`1.0` 小数、指数）；正整数超过 int64 上限时
//     保留为无符号 64 位；数值字符串不作二次解释（桶值的十进制字符串语义在
//     metrics_store 的 curve 编解码里处理）。
//   - 写：紧凑输出；Int/UInt 输出十进制整数；Double 输出最短往返十进制；
//     字符串按 JSON 转义（含控制字符），非 ASCII 原样输出 UTF-8。
//   - 安全上限：深度、节点数、单字符串长度、整体文本大小由调用方限制；
//     拒绝重复键、拒绝顶层之后的尾随内容、拒绝非法 UTF-8。
//
// 契约：CONTRACT_096 §1.1（读端忽略未知字段、写端保留未知字段）、§4.2、§4.3。

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace niuma {
namespace metrics {
namespace json {

enum class ParseError : std::uint8_t {
  None,
  Empty,
  Syntax,
  Depth,
  Nodes,
  StringLength,
  NumberRange,
  DuplicateKey,
  TrailingContent,
  NotUtf8,
};

struct ParseLimits {
  std::size_t maxNodes = 200000;
  int maxDepth = 64;
  std::size_t maxStringBytes = 1u << 20;
};

class Value;
using Object = std::vector<std::pair<std::string, Value>>;
using Array = std::vector<Value>;

class Value {
 public:
  enum class Type : std::uint8_t { Null, Bool, Int, UInt, Double, String, Array, Object };

  Value() = default;  // Null

  static Value MakeBool(bool value) {
    Value out;
    out.type_ = Type::Bool;
    out.bool_ = value;
    return out;
  }
  static Value MakeInt(std::int64_t value) {
    Value out;
    out.type_ = Type::Int;
    out.int_ = value;
    return out;
  }
  static Value MakeUInt(std::uint64_t value) {
    Value out;
    out.type_ = Type::UInt;
    out.uint_ = value;
    return out;
  }
  static Value MakeDouble(double value) {
    Value out;
    out.type_ = Type::Double;
    out.double_ = value;
    return out;
  }
  static Value MakeString(std::string value) {
    Value out;
    out.type_ = Type::String;
    out.string_ = std::move(value);
    return out;
  }
  static Value MakeArray(Array items) {
    Value out;
    out.type_ = Type::Array;
    out.array_ = std::move(items);
    return out;
  }
  static Value MakeObject(Object members) {
    Value out;
    out.type_ = Type::Object;
    out.object_ = std::move(members);
    return out;
  }

  Type type() const noexcept { return type_; }
  bool IsNull() const noexcept { return type_ == Type::Null; }
  bool IsBool() const noexcept { return type_ == Type::Bool; }
  bool IsInt() const noexcept { return type_ == Type::Int; }
  bool IsUInt() const noexcept { return type_ == Type::UInt; }
  bool IsDouble() const noexcept { return type_ == Type::Double; }
  bool IsNumber() const noexcept {
    return type_ == Type::Int || type_ == Type::UInt || type_ == Type::Double;
  }
  bool IsString() const noexcept { return type_ == Type::String; }
  bool IsArray() const noexcept { return type_ == Type::Array; }
  bool IsObject() const noexcept { return type_ == Type::Object; }

  // Type-checked accessors; wrong types return zero/empty defaults.
  bool Bool() const noexcept { return IsBool() && bool_; }
  std::int64_t Int() const noexcept {
    if (type_ == Type::Int) return int_;
    if (type_ == Type::UInt && uint_ <= static_cast<std::uint64_t>(
                                           std::numeric_limits<std::int64_t>::max()))
      return static_cast<std::int64_t>(uint_);
    return 0;
  }
  std::uint64_t UInt() const noexcept {
    if (type_ == Type::UInt) return uint_;
    if (type_ == Type::Int && int_ >= 0) return static_cast<std::uint64_t>(int_);
    return 0;
  }
  double Number() const noexcept {
    switch (type_) {
      case Type::Int: return static_cast<double>(int_);
      case Type::UInt: return static_cast<double>(uint_);
      case Type::Double: return double_;
      default: return 0.0;
    }
  }
  const std::string& Str() const noexcept { return string_; }
  const Array& Items() const noexcept { return array_; }
  Array& Items() noexcept { return array_; }
  const Object& Members() const noexcept { return object_; }
  Object& Members() noexcept { return object_; }

  // Object-only helpers. Find returns nullptr for absent key or non-objects.
  const Value* Find(std::string_view key) const noexcept {
    if (!IsObject()) return nullptr;
    for (const auto& member : object_)
      if (member.first == key) return &member.second;
    return nullptr;
  }
  // Replace an existing key in place, or append it. Object-only; no-op others.
  void Set(std::string key, Value value) {
    if (!IsObject()) return;
    for (auto& member : object_) {
      if (member.first == key) {
        member.second = std::move(value);
        return;
      }
    }
    object_.emplace_back(std::move(key), std::move(value));
  }

 private:
  Type type_ = Type::Null;
  bool bool_ = false;
  std::int64_t int_ = 0;
  std::uint64_t uint_ = 0;
  double double_ = 0.0;
  std::string string_;
  Array array_;
  Object object_;
};

struct ParseResult {
  ParseError error = ParseError::None;
  std::size_t offset = 0;  // Byte offset of the failure site, for diagnostics.
  Value value;
};

// Parses one complete JSON document. Rejects trailing content after the root
// value. `text` must outlive only the call; the returned tree owns copies.
ParseResult Parse(std::string_view text, const ParseLimits& limits = {});

// Serializes compactly (no whitespace). Non-finite doubles become null.
std::string Serialize(const Value& value);

// ---- tolerant field readers used by the block codecs ----

// Accepts Bool only (JSON true/false).
inline bool GetBool(const Value& value, bool* out) {
  if (!value.IsBool() || !out) return false;
  *out = value.Bool();
  return true;
}

// Accepts Int, UInt, Double with an exact integer value, or a decimal string
// that parses fully as an unsigned 64-bit integer (contract §4.3 buckets).
bool GetU64(const Value& value, std::uint64_t* out);

// Accepts any JSON number or a decimal string; range-checked doubles only.
bool GetDouble(const Value& value, double* out);

// Accepts String only.
inline bool GetString(const Value& value, std::string* out) {
  if (!value.IsString() || !out) return false;
  *out = value.Str();
  return true;
}

// ---- implementation ----

namespace detail {

inline bool GetU64(const Value& value, std::uint64_t* out) {
  if (!out) return false;
  if (value.IsUInt()) {
    *out = value.UInt();
    return true;
  }
  if (value.IsInt()) {
    if (value.Int() < 0) return false;
    *out = static_cast<std::uint64_t>(value.Int());
    return true;
  }
  if (value.IsDouble()) {
    const double number = value.Number();
    if (number < 0.0 ||
        number >= 18446744073709551616.0 ||  // 2^64: exactly out of range.
        number != std::floor(number))
      return false;
    *out = static_cast<std::uint64_t>(number);
    return true;
  }  if (value.IsString()) {
    const std::string& text = value.Str();
    if (text.empty() || text.size() > 20) return false;
    for (char c : text)
      if (c < '0' || c > '9') return false;
    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
    if (end != text.c_str() + text.size() || errno == ERANGE) return false;
    *out = static_cast<std::uint64_t>(parsed);
    return true;
  }
  return false;
}

inline bool GetDouble(const Value& value, double* out) {
  if (!out) return false;
  if (value.IsNumber()) {
    *out = value.Number();
    return true;
  }
  if (value.IsString()) {
    const std::string& text = value.Str();
    if (text.empty() || text.size() > 32) return false;
    errno = 0;
    char* end = nullptr;
    const double parsed = std::strtod(text.c_str(), &end);
    if (end != text.c_str() + text.size() || errno == ERANGE) return false;
    *out = parsed;
    return true;
  }
  return false;
}

}  // namespace detail

inline bool GetU64(const Value& value, std::uint64_t* out) {
  return detail::GetU64(value, out);
}
inline bool GetDouble(const Value& value, double* out) {
  return detail::GetDouble(value, out);
}

namespace detail {

class Parser {
 public:
  Parser(std::string_view text, const ParseLimits& limits)
      : text_(text), limits_(limits) {}

  ParseResult Run() {
    ParseResult result;
    if (text_.empty()) {
      result.error = ParseError::Empty;
      return result;
    }
    SkipSpaces();
    if (!ParseValue(0, &result.value)) {
      result.error = error_;
      result.offset = offset_;
      return result;
    }
    SkipSpaces();
    if (position_ != text_.size()) {
      result.error = ParseError::TrailingContent;
      result.offset = position_;
      return result;
    }
    return result;
  }

 private:
  void SkipSpaces() {
    while (position_ < text_.size()) {
      const char c = text_[position_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++position_;
      else break;
    }
  }

  bool Fail(ParseError error, std::size_t offset) {
    if (error_ == ParseError::None) {
      error_ = error;
      offset_ = offset;
    }
    return false;
  }

  bool ParseValue(int depth, Value* out) {
    if (depth > limits_.maxDepth) return Fail(ParseError::Depth, position_);
    if (nodes_ >= limits_.maxNodes) return Fail(ParseError::Nodes, position_);
    ++nodes_;
    if (position_ >= text_.size()) return Fail(ParseError::Syntax, position_);
    const char c = text_[position_];
    switch (c) {
      case '{': return ParseObject(depth, out);
      case '[': return ParseArray(depth, out);
      case '"': {
        std::string decoded;
        if (!ParseString(&decoded)) return false;
        *out = Value::MakeString(std::move(decoded));
        return true;
      }
      case 't': return ParseLiteral("true", Value::MakeBool(true), out);
      case 'f': return ParseLiteral("false", Value::MakeBool(false), out);
      case 'n': return ParseLiteral("null", Value(), out);
      default: return ParseNumber(out);
    }
  }

  bool ParseLiteral(const char* literal, Value value, Value* out) {
    const std::size_t length = std::strlen(literal);
    if (text_.size() - position_ < length ||
        std::memcmp(text_.data() + position_, literal, length) != 0)
      return Fail(ParseError::Syntax, position_);
    position_ += length;
    *out = std::move(value);
    return true;
  }

  bool ParseObject(int depth, Value* out) {
    ++position_;  // '{'
    Object members;
    SkipSpaces();
    if (position_ < text_.size() && text_[position_] == '}') {
      ++position_;
      *out = Value::MakeObject(std::move(members));
      return true;
    }
    while (true) {
      SkipSpaces();
      if (position_ >= text_.size() || text_[position_] != '"')
        return Fail(ParseError::Syntax, position_);
      std::string key;
      if (!ParseString(&key)) return false;
      if (key.size() > limits_.maxStringBytes)
        return Fail(ParseError::StringLength, position_);
      SkipSpaces();
      if (position_ >= text_.size() || text_[position_] != ':')
        return Fail(ParseError::Syntax, position_);
      ++position_;
      SkipSpaces();
      Value member;
      if (!ParseValue(depth + 1, &member)) return false;
      for (const auto& existing : members)
        if (existing.first == key) return Fail(ParseError::DuplicateKey, position_);
      members.emplace_back(std::move(key), std::move(member));
      SkipSpaces();
      if (position_ >= text_.size()) return Fail(ParseError::Syntax, position_);
      if (text_[position_] == ',') {
        ++position_;
        continue;
      }
      if (text_[position_] == '}') {
        ++position_;
        *out = Value::MakeObject(std::move(members));
        return true;
      }
      return Fail(ParseError::Syntax, position_);
    }
  }

  bool ParseArray(int depth, Value* out) {
    ++position_;  // '['
    Array items;
    SkipSpaces();
    if (position_ < text_.size() && text_[position_] == ']') {
      ++position_;
      *out = Value::MakeArray(std::move(items));
      return true;
    }
    while (true) {
      SkipSpaces();
      Value item;
      if (!ParseValue(depth + 1, &item)) return false;
      items.push_back(std::move(item));
      SkipSpaces();
      if (position_ >= text_.size()) return Fail(ParseError::Syntax, position_);
      if (text_[position_] == ',') {
        ++position_;
        continue;
      }
      if (text_[position_] == ']') {
        ++position_;
        *out = Value::MakeArray(std::move(items));
        return true;
      }
      return Fail(ParseError::Syntax, position_);
    }
  }

  bool ParseString(std::string* out) {
    ++position_;  // '"'
    const std::size_t start = position_;
    std::string decoded;
    // Plain runs are appended lazily; anything already written goes to
    // `decoded`, so later bytes must always be appended there too.
    std::size_t plainStart = position_;
    auto flushPlain = [&](std::size_t end) {
      if (end > plainStart) decoded.append(text_.data() + plainStart, end - plainStart);
    };
    while (true) {
      if (position_ >= text_.size()) return Fail(ParseError::Syntax, start);
      const unsigned char c = static_cast<unsigned char>(text_[position_]);
      if (c == '"') {
        flushPlain(position_);
        ++position_;
        if (decoded.size() > limits_.maxStringBytes)
          return Fail(ParseError::StringLength, start);
        *out = std::move(decoded);
        return true;
      }
      if (c == '\\') {
        flushPlain(position_);
        if (!ParseEscape(&decoded)) return false;
        plainStart = position_;  // The escape consumed its own characters.
        continue;
      }
      if (c < 0x20) return Fail(ParseError::Syntax, position_);
      if (c < 0x80) {
        ++position_;
        continue;
      }
      const std::size_t sequence = Utf8SequenceLength(c);
      if (sequence == 0 || position_ + sequence > text_.size() ||
          !Utf8RunValid(text_, position_, sequence))
        return Fail(ParseError::NotUtf8, position_);
      position_ += sequence;
    }
  }

  bool ParseEscape(std::string* out) {
    const std::size_t escape = position_;
    ++position_;  // '\'
    if (position_ >= text_.size()) return Fail(ParseError::Syntax, escape);
    const char c = text_[position_++];
    switch (c) {
      case '"': out->push_back('"'); return true;
      case '\\': out->push_back('\\'); return true;
      case '/': out->push_back('/'); return true;
      case 'b': out->push_back('\b'); return true;
      case 'f': out->push_back('\f'); return true;
      case 'n': out->push_back('\n'); return true;
      case 'r': out->push_back('\r'); return true;
      case 't': out->push_back('\t'); return true;
      case 'u': break;
      default: return Fail(ParseError::Syntax, escape);
    }
    std::uint32_t code = 0;
    if (!ParseHex4(escape, &code)) return false;
    if (code >= 0xd800 && code <= 0xdbff) {
      // High surrogate: require an immediately following low surrogate.
      if (position_ + 1 >= text_.size() || text_[position_] != '\\' ||
          text_[position_ + 1] != 'u')
        return Fail(ParseError::NotUtf8, escape);
      position_ += 2;
      std::uint32_t low = 0;
      if (!ParseHex4(escape, &low) || low < 0xdc00 || low > 0xdfff)
        return Fail(ParseError::NotUtf8, escape);
      code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return Fail(ParseError::NotUtf8, escape);  // Lone low surrogate.
    }
    AppendUtf8(code, out);
    return true;
  }

  bool ParseHex4(std::size_t escape, std::uint32_t* out) {
    if (position_ + 4 > text_.size()) return Fail(ParseError::Syntax, escape);
    std::uint32_t value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[position_++];
      value <<= 4;
      if (c >= '0' && c <= '9') value |= static_cast<std::uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') value |= static_cast<std::uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') value |= static_cast<std::uint32_t>(c - 'A' + 10);
      else return Fail(ParseError::Syntax, position_ - 1);
    }
    *out = value;
    return true;
  }

  static void AppendUtf8(std::uint32_t code, std::string* out) {
    if (code < 0x80) {
      out->push_back(static_cast<char>(code));
    } else if (code < 0x800) {
      out->push_back(static_cast<char>(0xc0 | (code >> 6)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else if (code < 0x10000) {
      out->push_back(static_cast<char>(0xe0 | (code >> 12)));
      out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else {
      out->push_back(static_cast<char>(0xf0 | (code >> 18)));
      out->push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
      out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
    }
  }

  bool ParseNumber(Value* out) {
    const std::size_t start = position_;
    bool floating = false;
    if (position_ < text_.size() && text_[position_] == '-') ++position_;
    // Integer part: "0" or [1-9][0-9]*, no leading zeros.
    if (position_ >= text_.size() || text_[position_] < '0' || text_[position_] > '9')
      return Fail(ParseError::Syntax, start);
    if (text_[position_] == '0') {
      ++position_;
    } else {
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9')
        ++position_;
    }
    if (position_ < text_.size() && text_[position_] == '.') {
      floating = true;
      ++position_;
      if (position_ >= text_.size() || text_[position_] < '0' || text_[position_] > '9')
        return Fail(ParseError::Syntax, position_);
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9')
        ++position_;
    }
    if (position_ < text_.size() &&
        (text_[position_] == 'e' || text_[position_] == 'E')) {
      floating = true;
      ++position_;
      if (position_ < text_.size() &&
          (text_[position_] == '+' || text_[position_] == '-'))
        ++position_;
      if (position_ >= text_.size() || text_[position_] < '0' || text_[position_] > '9')
        return Fail(ParseError::Syntax, position_);
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9')
        ++position_;
    }
    const std::string digits(text_.substr(start, position_ - start));
    if (digits.size() > 64) return Fail(ParseError::NumberRange, start);
    if (!floating) {
      if (digits[0] == '-') {
        errno = 0;
        char* end = nullptr;
        const long long parsed = std::strtoll(digits.c_str(), &end, 10);
        if (end != digits.c_str() + digits.size() || errno == ERANGE)
          return Fail(ParseError::NumberRange, start);
        *out = Value::MakeInt(static_cast<std::int64_t>(parsed));
      } else {
        errno = 0;
        char* end = nullptr;
        const unsigned long long parsed = std::strtoull(digits.c_str(), &end, 10);
        if (end != digits.c_str() + digits.size() || errno == ERANGE)
          return Fail(ParseError::NumberRange, start);
        *out = Value::MakeUInt(static_cast<std::uint64_t>(parsed));
      }
      return true;
    }
    errno = 0;
    char* end = nullptr;
    const double parsed = std::strtod(digits.c_str(), &end);
    if (end != digits.c_str() + digits.size() || errno == ERANGE)
      return Fail(ParseError::NumberRange, start);
    *out = Value::MakeDouble(parsed);
    return true;
  }

  static std::size_t Utf8SequenceLength(unsigned char lead) {
    if (lead >= 0xc2 && lead <= 0xdf) return 2;
    if (lead >= 0xe0 && lead <= 0xef) return 3;
    if (lead >= 0xf0 && lead <= 0xf4) return 4;
    return 0;  // Continuation bytes, C0/C1, F5-FF.
  }

  static bool Utf8RunValid(std::string_view text, std::size_t start,
                           std::size_t length) {
    const auto at = [text](std::size_t index) {
      return static_cast<unsigned char>(text[index]);
    };
    const unsigned char lead = at(start);
    bool bounded = false;
    switch (length) {
      case 2:
        bounded = true;  // C2-DF always yields U+0080..U+07FF.
        break;
      case 3:
        if (lead == 0xe0) bounded = at(start + 1) >= 0xa0;
        else if (lead == 0xed) bounded = at(start + 1) <= 0x9f;  // No surrogates.
        else bounded = true;
        break;
      case 4:
        if (lead == 0xf0) bounded = at(start + 1) >= 0x90;
        else if (lead == 0xf4) bounded = at(start + 1) <= 0x8f;  // ≤ U+10FFFF.
        else bounded = true;
        break;
      default: return false;
    }
    if (!bounded) return false;
    for (std::size_t i = 1; i < length; ++i)
      if (at(start + i) < 0x80 || at(start + i) > 0xbf) return false;
    return true;
  }

  std::string_view text_;
  ParseLimits limits_;
  std::size_t position_ = 0;
  std::size_t nodes_ = 0;
  ParseError error_ = ParseError::None;
  std::size_t offset_ = 0;
};

class Writer {
 public:
  void Write(const Value& value) { WriteValue(value); }
  const std::string& Take() const noexcept { return out_; }
  std::string Take() { return std::move(out_); }

 private:
  void WriteValue(const Value& value) {
    switch (value.type()) {
      case Value::Type::Null: out_ += "null"; break;
      case Value::Type::Bool: out_ += value.Bool() ? "true" : "false"; break;
      case Value::Type::Int: WriteInt(value.Int()); break;
      case Value::Type::UInt: WriteUInt(value.UInt()); break;
      case Value::Type::Double: WriteDouble(value.Number()); break;
      case Value::Type::String: WriteString(value.Str()); break;
      case Value::Type::Array: {
        out_ += '[';
        bool first = true;
        for (const auto& item : value.Items()) {
          if (!first) out_ += ',';
          first = false;
          WriteValue(item);
        }
        out_ += ']';
        break;
      }
      case Value::Type::Object: {
        out_ += '{';
        bool first = true;
        for (const auto& member : value.Members()) {
          if (!first) out_ += ',';
          first = false;
          WriteString(member.first);
          out_ += ':';
          WriteValue(member.second);
        }
        out_ += '}';
        break;
      }
    }
  }

  void WriteInt(std::int64_t value) {
    char buffer[32];
    const int length = std::snprintf(buffer, sizeof(buffer), "%lld",
        static_cast<long long>(value));
    out_.append(buffer, static_cast<std::size_t>(length));
  }

  void WriteUInt(std::uint64_t value) {
    char buffer[32];
    const int length = std::snprintf(buffer, sizeof(buffer), "%llu",
        static_cast<unsigned long long>(value));
    out_.append(buffer, static_cast<std::size_t>(length));
  }

  // Shortest decimal form that round-trips through strtod, without exponent
  // forms below 1e15 magnitude (keeps prefs human-readable like "1" or "0.75").
  void WriteDouble(double value) {
    if (value != value || value == std::numeric_limits<double>::infinity() ||
        value == -std::numeric_limits<double>::infinity()) {
      out_ += "null";
      return;
    }
    char buffer[64];
    for (int precision = 1; precision <= 17; ++precision) {
      const int length = std::snprintf(buffer, sizeof(buffer), "%.*g", precision,
                                       value);
      if (length <= 0) break;
      errno = 0;
      char* end = nullptr;
      const double roundTrip = std::strtod(buffer, &end);
      if (end == buffer + length && errno != ERANGE && roundTrip == value) {
        // Prefer a plain decimal; %g may choose "1e+06" style for big/small
        // magnitudes, which is valid JSON and accepted by the parser.
        out_.append(buffer, static_cast<std::size_t>(length));
        return;
      }
    }
    const int length = std::snprintf(buffer, sizeof(buffer), "%.17g", value);
    out_.append(buffer, static_cast<std::size_t>(length));
  }

  void WriteString(const std::string& text) {
    out_ += '"';
    std::size_t plainStart = 0;
    const std::size_t size = text.size();
    auto flush = [&](std::size_t end) {
      if (end > plainStart) out_.append(text, plainStart, end - plainStart);
    };
    for (std::size_t i = 0; i < size; ++i) {
      const unsigned char c = static_cast<unsigned char>(text[i]);
      const char* escape = nullptr;
      char unicode[8] = {};
      switch (c) {
        case '"': escape = "\\\""; break;
        case '\\': escape = "\\\\"; break;
        case '\b': escape = "\\b"; break;
        case '\f': escape = "\\f"; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default:
          if (c < 0x20) {
            std::snprintf(unicode, sizeof(unicode), "\\u%04x", c);
            escape = unicode;
          }
          break;
      }
      if (escape != nullptr) {
        flush(i);
        out_ += escape;
        plainStart = i + 1;
      }
    }
    flush(size);
    out_ += '"';
  }

  std::string out_;
};

}  // namespace detail

inline ParseResult Parse(std::string_view text, const ParseLimits& limits) {
  detail::Parser parser(text, limits);
  return parser.Run();
}

inline std::string Serialize(const Value& value) {
  detail::Writer writer;
  writer.Write(value);
  return writer.Take();
}

}  // namespace json
}  // namespace metrics
}  // namespace niuma
