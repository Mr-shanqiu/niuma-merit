#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UiText 多语词条覆盖自检（0.9.6 · 9 语：zh-Hans/zh-Hant/ja/ko/th/fr/es/de）。

自动识别仓库布局：
  * macOS：macos/src/macos/ui_text_table.h + macos/src/macos/*.mm（@"..." 字面量）
  * Windows：windows/src/windows/ui_text_table.h + windows/src/windows/*.cpp（L"..." 字面量）

校验：
  1. 调用点总数 / 去重键数 / 词条数；
  2. 缺词条：调用点出现但表里没有（回落简中，视为覆盖缺口）；
  3. 僵尸词条：表里有但没有任何调用点使用（信息性）；
  4. 新增列 th/fr/es/de 覆盖率：任一词条缺任一列即报错（"缺一即报错"）；
  5. 格式说明符（%@/%ld/%lu/%d/%02ld/%.1f/%%...）在 zh-Hant/ja/ko/th/fr/es/de
     与键之间必须完全一致，否则 NSString/Format 会错位。

存在缺词条、缺新列或说明符不一致时退出码为 1。
"""
import collections
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
MAC_TABLE = os.path.join(REPO, "macos", "src", "macos", "ui_text_table.h")
WIN_TABLE = os.path.join(REPO, "windows", "src", "windows", "ui_text_table.h")

C_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}
LANGS = ("zh-Hant", "ja", "ko", "th", "fr", "es", "de")


def parse_c_literal_body(body: str) -> str:
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\":
            nxt = body[i + 1] if i + 1 < len(body) else ""
            if nxt in C_ESCAPES:
                out.append(C_ESCAPES[nxt]); i += 2; continue
            if nxt == "u":
                out.append(chr(int(body[i + 2 : i + 6], 16))); i += 6; continue
            if nxt == "x":
                m = re.match(r"x([0-9a-fA-F]{1,2})", body[i + 1 :])
                out.append(chr(int(m.group(1), 16))); i += 1 + m.end(); continue
            out.append(nxt); i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def parse_literals(source: str, start: int, prefix: str):
    i = start; parts = []
    while True:
        j = i
        while j < len(source) and source[j] in " \t\r\n":
            j += 1
        if source.startswith(prefix, j):
            p = j + len(prefix); buf = []
            while p < len(source):
                c = source[p]
                if c == "\\":
                    buf.append(c)
                    if p + 1 < len(source):
                        buf.append(source[p + 1])
                    p += 2; continue
                if c == '"':
                    p += 1; break
                buf.append(c); p += 1
            parts.append(parse_c_literal_body("".join(buf))); i = p; continue
        break
    if not parts:
        return None, start
    return "".join(parts), i


def iter_calls(source, prefix):
    pos = 0
    while True:
        m = re.search(r"UiText\s*\(", source[pos:])
        if not m:
            return
        cursor = pos + m.end()
        zh, after = parse_literals(source, cursor, prefix)
        if zh is None:
            pos = cursor; continue
        en = ""
        k = after
        while k < len(source) and source[k] in " \t\r\n":
            k += 1
        if k < len(source) and source[k] == ",":
            en, _ = parse_literals(source, k + 1, prefix)
            en = en or ""
        yield zh, en
        pos = after


SPEC_RE = re.compile(r"%(?:%|[0-9.]*l?[douxXeEfgGsSc]|@)")


def specs(s):
    return collections.Counter(SPEC_RE.findall(s))


def load_table(table_path, wide):
    entries = {}
    with open(table_path, encoding="utf-8") as f:
        text = f.read()
    lit = r'L?"((?:[^"\\]|\\.)*)"'
    pat = re.compile(r"\{\s*" + r",\s*".join([lit] * 8) + r"\s*\}")
    for m in pat.finditer(text):
        vals = [parse_c_literal_body(m.group(i)) for i in range(1, 9)]
        entries[vals[0]] = tuple(vals[1:])  # hant,ja,ko,th,fr,es,de
    return entries


def main():
    win_primary = os.path.exists(os.path.join(REPO, "windows", "CMakeLists.txt"))
    if win_primary and os.path.exists(WIN_TABLE):
        table_path = WIN_TABLE; prefix = 'L"'; src_glob = os.path.join(REPO, "windows", "src", "windows", "*.cpp")
    elif os.path.exists(MAC_TABLE):
        table_path = MAC_TABLE; prefix = '@"'; src_glob = os.path.join(REPO, "macos", "src", "macos", "*.mm")
    elif os.path.exists(WIN_TABLE):
        table_path = WIN_TABLE; prefix = 'L"'; src_glob = os.path.join(REPO, "windows", "src", "windows", "*.cpp")
    else:
        print("找不到 ui_text_table.h（mac/windows 布局均未匹配）"); return 2

    call_sites = 0
    keys = collections.OrderedDict()
    for path in sorted(glob.glob(src_glob)):
        with open(path, encoding="utf-8") as f:
            source = f.read()
        if "ui_text.cpp" in path:
            continue
        for zh, en in iter_calls(source, prefix):
            call_sites += 1
            keys.setdefault(zh, []).append((os.path.basename(path), en))
    entries = load_table(table_path, prefix == 'L"')

    missing = [k for k in keys if k not in entries]
    stale = [k for k in entries if k not in keys]
    empty_cols = []
    bad_specs = []
    for key, vals in entries.items():
        for lang, value in zip(LANGS, vals):
            if not value.strip():
                empty_cols.append((lang, key))
            elif specs(key) != specs(value):
                bad_specs.append((lang, key))

    print("布局:            %s" % ("Windows(wchar_t)" if prefix == 'L"' else "macOS(NSString)"))
    print("UiText 调用点总数: %d" % call_sites)
    print("去重简中键数:     %d" % len(keys))
    print("字符串表词条数:   %d" % len(entries))
    print("缺词条(回落简中): %d" % len(missing))
    print("僵尸词条(未使用): %d" % len(stale))
    print("缺新列(th/fr/es/de): %d" % len(empty_cols))
    print("说明符不一致:     %d" % len(bad_specs))
    for k in missing:
        print("  MISSING:", repr(k))
    for k in stale[:10]:
        print("  STALE:  ", repr(k))
    if len(stale) > 10:
        print("  ... (%d more unused keys)" % (len(stale) - 10))
    for lang, k in empty_cols:
        print("  EMPTYCOL:", lang, repr(k))
    for lang, k in bad_specs:
        print("  BADSPEC:", lang, repr(k))
    if missing or empty_cols or bad_specs:
        return 1
    print("OK: 全部调用点均有词条，9 语新列齐备，格式说明符一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
