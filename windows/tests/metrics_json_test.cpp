// metrics_json.h 纯逻辑自测：数字（整数/小数/大数）、字符串（转义/UTF-8/代用对）、
// 重复键、尾随内容、深度/节点上限、往返序列化。
// 编译：clang++ -std=c++17 -I ../src/client/core metrics_json_test.cpp -o /tmp/mj_test
#include "metrics_json.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>

using niuma::metrics::json::Array;
using niuma::metrics::json::Object;
using niuma::metrics::json::Parse;
using niuma::metrics::json::ParseError;
using niuma::metrics::json::ParseLimits;
using niuma::metrics::json::Serialize;
using niuma::metrics::json::Value;

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

static Value P(const std::string& text) {
  const auto result = Parse(text);
  CHECK(result.error == ParseError::None);
  return result.value;
}

int main() {
  // --- 数字：整数、uint64 全量程、小数、指数 ---
  {
    const Value value = P("0");
    CHECK(value.IsUInt() && value.UInt() == 0);
  }
  {
    const Value value = P("-42");
    CHECK(value.IsInt() && value.Int() == -42);
  }
  {
    const Value value = P("18446744073709551615");
    CHECK(value.IsUInt());
    CHECK(value.UInt() == std::numeric_limits<std::uint64_t>::max());
  }
  {
    // int64 下限。
    const Value value = P("-9223372036854775808");
    CHECK(value.IsInt());
    CHECK(value.Int() == std::numeric_limits<std::int64_t>::min());
  }
  {
    // 2^63：作为无符号精确表示。
    const Value value = P("9223372036854775808");
    CHECK(value.IsUInt() && value.UInt() == 9223372036854775808ull);
  }
  {
    const Value value = P("1.0");
    CHECK(value.IsDouble());
    CHECK(std::fabs(value.Number() - 1.0) < 1e-12);
  }
  {
    const Value value = P("-0.75e-2");
    CHECK(value.IsDouble());
    CHECK(std::fabs(value.Number() + 0.0075) < 1e-12);
  }
  {
    // 前导零与裸小数点是语法错误。
    const auto bad = Parse("01");
    CHECK(bad.error != ParseError::None);
    const auto badDot = Parse("1.");
    CHECK(badDot.error != ParseError::None);
    const auto badExp = Parse("1e");
    CHECK(badExp.error != ParseError::None);
    const auto leadingPlus = Parse("+1");
    CHECK(leadingPlus.error != ParseError::None);
    const auto nan = Parse("NaN");
    CHECK(nan.error != ParseError::None);
  }

  // --- 字符串：转义、控制字符、UTF-8、代用对 ---
  {
    const Value value = P("\"a\\nb\\u4e2d\\ud83d\\ude00\"");
    CHECK(value.IsString());
    CHECK(value.Str() == std::string("a\nb\xE4\xB8\xAD\xF0\x9F\x98\x80"));
  }
  {
    // 孤立低代理是错误。
    const auto bad = Parse("\"\\udc00\"");
    CHECK(bad.error == ParseError::NotUtf8);
    // 控制字符必须转义。
    const auto raw = Parse(std::string("\"a\x01b\""));
    CHECK(raw.error != ParseError::None);
    // 非法 UTF-8（C0 80 是过长的 NUL 编码）。
    const auto invalid = Parse(std::string("\"a\xC0\x80" "b\""));
    CHECK(invalid.error == ParseError::NotUtf8);
    const auto truncated = Parse(std::string("\"a\xE4\xB8\""));
    CHECK(truncated.error == ParseError::NotUtf8);
  }
  {
    // 转义后仍能继续取普通文本（延迟拼接路径）。
    const Value value = P("\"\\tXYZ\\nABC\"");
    CHECK(value.Str() == std::string("\tXYZ\nABC"));
  }

  // --- 结构：对象/数组/嵌套/空 ---
  {
    const Value value = P("{\"a\":[1,2,{\"b\":null}],\"c\":true}");
    CHECK(value.IsObject());
    const Value* a = value.Find("a");
    CHECK(a && a->IsArray() && a->Items().size() == 3);
    CHECK((*a).Items()[2].IsObject() && (*a).Items()[2].Find("b")->IsNull());
    CHECK(value.Find("c")->Bool());
  }
  {
    const Value value = P("  { }  ");
    CHECK(value.IsObject() && value.Members().empty());
    const Value array = P("[ ]");
    CHECK(array.IsArray() && array.Items().empty());
  }

  // --- 重复键 / 尾随内容 / 空输入 ---
  CHECK(Parse("{\"a\":1,\"a\":2}").error == ParseError::DuplicateKey);
  CHECK(Parse("{} {}").error == ParseError::TrailingContent);
  CHECK(Parse("[1]x").error == ParseError::TrailingContent);
  CHECK(Parse("").error == ParseError::Empty);
  CHECK(Parse("   ").error == ParseError::Syntax);
  CHECK(Parse("{").error != ParseError::None);
  CHECK(Parse("{\"a\":}").error != ParseError::None);
  CHECK(Parse("{\"a\" 1}").error != ParseError::None);

  // --- 深度 / 节点 / 字符串上限 ---
  {
    ParseLimits limits;
    limits.maxDepth = 4;
    std::string text;
    for (int i = 0; i < 10; ++i) text += "[";
    text += "1";
    for (int i = 0; i < 10; ++i) text += "]";
    CHECK(Parse(text, limits).error == ParseError::Depth);
  }
  {
    ParseLimits limits;
    limits.maxNodes = 5;
    CHECK(Parse("[1,2,3,4,5,6]", limits).error == ParseError::Nodes);
  }
  {
    ParseLimits limits;
    limits.maxStringBytes = 8;
    CHECK(Parse("\"abcdefghij\"", limits).error == ParseError::StringLength);
  }

  // --- GetU64 / GetDouble 兼容读取 ---
  {
    std::uint64_t out = 0;
    CHECK(niuma::metrics::json::GetU64(P("123"), &out) && out == 123);
    CHECK(niuma::metrics::json::GetU64(P("\"9007199254740993\""), &out) &&
          out == 9007199254740993ull);
    CHECK(niuma::metrics::json::GetU64(P("-5"), &out) == false);
    CHECK(niuma::metrics::json::GetU64(P("1.5"), &out) == false);
    CHECK(niuma::metrics::json::GetU64(P("\"12x\""), &out) == false);
    CHECK(niuma::metrics::json::GetU64(P("\"\""), &out) == false);
    // 指数按 double 处理：整值的 1e3 也可以读取。
    CHECK(niuma::metrics::json::GetU64(P("1e3"), &out) && out == 1000);
    CHECK(niuma::metrics::json::GetU64(P("1000.0"), &out) && out == 1000);
  }
  {
    double out = 0;
    CHECK(niuma::metrics::json::GetDouble(P("1.0"), &out) && out == 1.0);
    CHECK(niuma::metrics::json::GetDouble(P("\"0.75\""), &out) && out == 0.75);
    CHECK(niuma::metrics::json::GetDouble(P("2"), &out) && out == 2.0);
    CHECK(niuma::metrics::json::GetDouble(P("\"abc\""), &out) == false);
  }

  // --- 序列化：紧凑、转义、短往返 ---
  {
    Object members;
    members.emplace_back("n", Value::MakeInt(-7));
    members.emplace_back("u", Value::MakeUInt(18446744073709551615ull));
    members.emplace_back("d", Value::MakeDouble(1.5));
    members.emplace_back("s", Value::MakeString(std::string("q\"\\\n\x01")));
    members.emplace_back("arr", Value::MakeArray({Value::MakeBool(true), Value()}));
    const std::string text = Serialize(Value::MakeObject(std::move(members)));
    CHECK(text.find("\"u\":18446744073709551615") != std::string::npos);
    CHECK(text.find("\"s\":\"q\\\"\\\\\\n\\u0001\"") != std::string::npos);
    const Value back = P(text);
    CHECK(back.Find("u")->UInt() == 18446744073709551615ull);
    CHECK(std::fabs(back.Find("d")->Number() - 1.5) < 1e-15);
    CHECK(back.Find("s")->Str() == std::string("q\"\\\n\x01"));
  }
  {
    // Double 精确往返（含很小/较大值；整数样本可以回读为 Int/UInt 类型，
    // 数值语义一致，因此用 Number() 比较）。
    for (double sample : {0.1, 0.75, 1.0, 1.8, 123456.789, 1e15}) {
      const std::string text = Serialize(Value::MakeDouble(sample));
      const Value back = P(text);
      CHECK(back.IsNumber() && back.Number() == sample);
    }
    // 非有限值序列化为 null。
    CHECK(Serialize(Value::MakeDouble(std::nan("")) ) == "null");
  }
  {
    // 中文原样输出 UTF-8（不转 \u）。
    const std::string text = Serialize(Value::MakeString("中"));
    CHECK(text == "\"\xE4\xB8\xAD\"");
  }

  // --- Find/Set 对象操作 ---
  {
    Value object = P("{\"keep\":1,\"known\":2}");
    object.Set("known", Value::MakeInt(3));
    object.Set("added", Value::MakeBool(false));
    CHECK(object.Find("keep") && object.Find("keep")->Int() == 1);
    CHECK(object.Find("known")->Int() == 3);
    CHECK(object.Find("added")->Bool() == false);
    object.Set("n", Value());  // 非 JSON 有效输入不该崩溃（Null 合法）。
    CHECK(object.Members().size() == 4);
    Value scalar = Value::MakeInt(1);
    scalar.Set("x", Value::MakeInt(1));  // 非对象 no-op。
    CHECK(scalar.Int() == 1);
  }

  if (g_fail == 0) std::printf("metrics_json_test: OK (%d checks)\n", g_checks);
  else std::printf("metrics_json_test: FAILED (%d/%d)\n", g_fail, g_checks);
  return g_fail == 0 ? 0 : 1;
}
