#!/usr/bin/env python3
"""只读统计源包java.*的词法引用；不执行脚本，不输出规则、URL、源名或请求配置。"""
import argparse
import collections
import json
import re
from pathlib import Path

CALL = re.compile(r"\bjava\.([A-Za-z_$][\w$]*)\s*\(")


def calls(value):
    if isinstance(value, str):
        yield from CALL.findall(value)
    elif isinstance(value, dict):
        for nested in value.values():
            yield from calls(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from calls(nested)


def direct_exports(swift):
    # JSExport声明没有实现体；去注释后用括号层级避免被属性get/set的花括号截断。
    clean = re.sub(r"/\*.*?\*/|//[^\n]*", "", swift, flags=re.S)
    match = re.search(r"protocol\s+LegadoJSBridgeExport\s*:\s*JSExport\s*\{", clean)
    if not match:
        raise ValueError("未找到LegadoJSBridgeExport，不能生成虚假覆盖统计")
    depth, cursor = 1, match.end()
    while cursor < len(clean) and depth:
        depth += (clean[cursor] == "{") - (clean[cursor] == "}")
        cursor += 1
    if depth:
        raise ValueError("JSExport声明不完整")
    return set(re.findall(r"\bfunc\s+([A-Za-z_$][\w$]*)\s*\(", clean[match.end():cursor - 1]))


def summarize(records):
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        raise ValueError("源包必须为对象数组")
    mentions = collections.Counter()
    source_counts = collections.Counter()
    for record in records:
        current = collections.Counter(calls(record))
        mentions.update(current)
        source_counts.update(current.keys())
    return mentions, source_counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="脱敏Markdown统计文件")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    exports = direct_exports((root / "Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift").read_text(encoding="utf-8"))
    summaries = []
    for filename in ["rssSources-valid.json", "Booksource.json"]:
        records = json.loads((root / "docs" / filename).read_text(encoding="utf-8"))
        mentions, source_counts = summarize(records)
        summaries.append((filename, len(records), mentions, source_counts))
    lines = ["# 真实源包 java.* 静态引用统计", "", "命令：`python3 scripts/audit_source_java_calls.py --output docs/legado-alignment/java-static-audit.md`。",
             "", "本统计不执行脚本，不展开网络请求，不输出规则、URL、源名、请求头或账号数据。词法匹配也会包含字符串/注释中的提及，遗漏动态属性调用；它不是运行时覆盖率或所有源可用的证明。",
             "", "“直接导出”仅表示名字出现在 `LegadoJSBridgeExport` 的函数声明中，未验证参数、权限或RSS上下文。未命中者还需要核查JS shim、别名与固定Android基准，不能直接判为不支持。", ""]
    for filename, count, mentions, source_counts in summaries:
        lines += [f"## {filename}（{count}项）", "", f"词法函数名：{len(mentions)}；提及次数：{sum(mentions.values())}；含引用的源：{sum(bool(list(calls(item))) for item in json.loads((root / 'docs' / filename).read_text(encoding='utf-8')))}。", "",
                  "| java函数 | 涉及源数 | 提及次数 | 直接导出 |", "| --- | ---: | ---: | --- |"]
        for name in sorted(mentions):
            lines.append(f"| `{name}` | {source_counts[name]} | {mentions[name]} | {'是' if name in exports else '待核查'} |")
        lines.append("")
    lines += ["## RSS未直接导出项的复核", "",
              "- `createSymmetricCrypto`、`toURL`已有`LegadoJavaInteropRuntime`的JS shim；`toURL`返回URL组成对象，不表示开放任意文件/系统连接。",
              "- `getElement`由`JSCoreEngine.installJavaElementAccessors`转接`getElementValue`，直接函数名扫描不能识别该别名。",
              "- `addBook`在RSS包中有2项词法提及，当前桥未提供此名称；本次不盲目新增自动书架写入。需按具体交互确认与权限合同单独评估，不能宣称这些源全功能可用。", "",
              "## 范围判断", "", "先处理RSS包的“待核查”函数，并逐个查证真实调用所需能力；书源包单列，不据此扩大首期RSS范围。Dict、AutoTask/Cron、任意文件或系统能力仍不开放。",
              "", "新增压缩/字体能力前仍需实际需求、隔离fixture、许可和安全审查；不得按函数数量盲目补实现。", ""]
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(f"已生成脱敏静态统计：RSS={summaries[0][1]}，书源={summaries[1][1]}，直接导出函数={len(exports)}")


if __name__ == "__main__":
    main()
