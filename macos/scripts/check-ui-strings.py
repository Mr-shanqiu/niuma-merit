#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UiText 多语词条覆盖自检（0.9.6 L2）。

扫描 macos/src/macos/*.mm 中所有 UiText(@"简中", @"English") 调用点（含相邻
字符串字面量拼接），与 macos/src/macos/ui_text_table.h 的词条表对照：
  1. 调用点总数 / 去重键数 / 词条数；
  2. 缺词条：调用点出现但表里没有（zh-Hant/ja 将回落简中，视为覆盖缺口）；
  3. 僵尸词条：表里有但没有任何调用点使用；
  4. 格式说明符（%@/%ld/%lu/%d/%02ld/%.1f/%%...）在 zh-Hant、ja 与键之间
     必须完全一致（出现次数相同），否则 NSString 格式化会错位。

存在缺词条或说明符不一致时退出码为 1（可接入 CI / 构建前置检查）。
"""
import collections
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "..", "src", "macos")
TABLE_PATH = os.path.join(SRC_DIR, "ui_text_table.h")

C_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def parse_c_literal_body(body: str) -> str:
    """Decode the inside of a C/ObjC string literal (handles common escapes)."""
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\":
            nxt = body[i + 1] if i + 1 < len(body) else ""
            if nxt in C_ESCAPES:
                out.append(C_ESCAPES[nxt])
                i += 2
                continue
            if nxt == "u":
                out.append(chr(int(body[i + 2 : i + 6], 16)))
                i += 6
                continue
            if nxt == "x":
                m = re.match(r"x([0-9a-fA-F]{1,2})", body[i + 1 :])
                out.append(chr(int(m.group(1), 16)))
                i += 1 + m.end()
                continue
            out.append(nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_objc_literals(source: str, start: int):
    """Parse one or more adjacent @\"...\" literals beginning at/after `start`.

    Returns (decoded_concatenation, end_index) or (None, start)."""
    i = start
    parts = []
    while True:
        j = i
        while j < len(source) and source[j] in " \t\r\n":
            j += 1
        if j + 1 < len(source) and source[j] == "@" and source[j + 1] == '"':
            p = j + 2
            buf = []
            while p < len(source):
                c = source[p]
                if c == "\\":
                    buf.append(c)
                    if p + 1 < len(source):
                        buf.append(source[p + 1])
                    p += 2
                    continue
                if c == '"':
                    p += 1
                    break
                buf.append(c)
                p += 1
            parts.append(parse_c_literal_body("".join(buf)))
            i = p
            continue
        break
    if not parts:
        return None, start
    return "".join(parts), i


def iter_uitext_calls(source: str):
    """Yield (zh, en) for each UiText(...) call; skips the function definition."""
    pos = 0
    while True:
        m = re.search(r"UiText\s*\(", source[pos:])
        if not m:
            return
        cursor = pos + m.end()
        zh, after = parse_objc_literals(source, cursor)
        if zh is None:
            pos = cursor  # e.g. the UiText(NSString *chinese, ...) definition
            continue
        en = ""
        k = after
        while k < len(source) and source[k] in " \t\r\n":
            k += 1
        if k < len(source) and source[k] == ",":
            en, _ = parse_objc_literals(source, k + 1)
            en = en or ""
        yield zh, en
        pos = after


SPEC_RE = re.compile(r"%(?:%|[0-9.]*l?[douxXeEfgGsSc]|@)")


def specs(s: str):
    return collections.Counter(SPEC_RE.findall(s))


def load_table_entries():
    entries = {}
    with open(TABLE_PATH, encoding="utf-8") as f:
        text = f.read()
    for m in re.finditer(r'\{"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\}', text):
        zh_hans = parse_c_literal_body(m.group(1))
        entries[zh_hans] = (parse_c_literal_body(m.group(2)), parse_c_literal_body(m.group(3)))
    return entries


def main():
    call_sites = 0
    keys = collections.OrderedDict()
    for path in sorted(glob.glob(os.path.join(SRC_DIR, "*.mm"))):
        with open(path, encoding="utf-8") as f:
            source = f.read()
        for zh, en in iter_uitext_calls(source):
            call_sites += 1
            keys.setdefault(zh, []).append((os.path.basename(path), en))
    entries = load_table_entries()

    missing = [k for k in keys if k not in entries]
    stale = [k for k in entries if k not in keys]
    bad_specs = []
    for key, (zht, ja) in entries.items():
        for lang, value in (("zh-Hant", zht), ("ja", ja)):
            if specs(key) != specs(value):
                bad_specs.append((lang, key))

    print("UiText 调用点总数: %d" % call_sites)
    print("去重简中键数:     %d" % len(keys))
    print("字符串表词条数:   %d" % len(entries))
    print("缺词条(回落简中): %d" % len(missing))
    print("僵尸词条(未使用): %d" % len(stale))
    print("说明符不一致:     %d" % len(bad_specs))
    for k in missing:
        print("  MISSING:", repr(k))
    for k in stale:
        print("  STALE:  ", repr(k))
    for lang, k in bad_specs:
        print("  BADSPEC:", lang, repr(k))
    if missing or stale or bad_specs:
        return 1
    print("OK: 全部调用点均有 zh-Hant/ja 词条，格式说明符一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
