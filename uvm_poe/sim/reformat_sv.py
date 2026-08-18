# -*- coding: utf-8 -*-
"""将 uvm_poe 工程下的 SystemVerilog 源码统一为 4 空格层级缩进风格：
- 每个嵌套层级缩进 4 空格（begin/end、case、module/class/function、单语句控制、
  多行表达式续行等块结构感知）；
- 行内列对齐（端口/参数表、声明、实例化等）压缩为单空格分隔；
- 字符串字面量与 // 注释内容保持不变。

用法：python reformat_sv.py
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAB = "    "  # 4 空格一级

LEAD_DEC = {
    "end", "endcase", "endfunction", "endtask", "endmodule", "endclass",
    "endinterface", "endpackage", "endprogram", "endclocking", "endgenerate",
    "endproperty", "join", "join_any", "join_none",
}
LEAD_INC = {
    "module", "interface", "program", "package", "class", "function", "task",
    "clocking", "generate", "fork", "case", "casez", "casex",
}
CTRL_NO_SEMI = {"if", "for", "while", "foreach", "repeat"}
PRAGMA = {
    "ifdef", "ifndef", "else", "endif", "define", "include", "timescale",
    "resetall", "celldefine", "endcelldefine", "default_nettype", "undef",
}


def squeeze_inline(line):
    """压缩字符串与注释之外的连续空格为单空格；保留注释/字符串内容。"""
    out = []
    i, n = 0, len(line)
    in_str = False
    while i < n:
        c = line[i]
        if c == '"':
            in_str = not in_str
            out.append(c)
            i += 1
            continue
        if not in_str and c == "/" and i + 1 < n and line[i + 1] == "/":
            if out and out[-1] != " ":
                out.append(" ")
            out.append(line[i:])
            break
        if not in_str and (c == " " or c == "\t"):
            while i < n and line[i] in " \t":
                i += 1
            out.append(" ")
            continue
        out.append(c)
        i += 1
    return "".join(out).rstrip()


def strip_comment(line):
    """去掉 // 注释（字符串字面量内除外），用于行尾 begin/分号/冒号判断。"""
    out = []
    i, n = 0, len(line)
    in_str = False
    while i < n:
        c = line[i]
        if c == '"':
            in_str = not in_str
            out.append(c)
            i += 1
            continue
        if not in_str and c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out).rstrip()


def first_word(line):
    m = re.match(r"(\w+)", line)
    return m.group(1) if m else ""


def pop_single(dims, kinds=("s", "e")):
    """弹出栈顶单语句/续行作用域（块开始前被吸收）。"""
    while dims and dims[-1] in kinds:
        dims.pop()


def reindent(text):
    lines = text.splitlines()
    out = []
    dims = []  # 栈：'b' 块 / 's' 无 begin 单语句控制 / 'e' 多行表达式续行
    n = len(lines)
    for idx, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped:
            out.append("")
            continue
        # 预处理指令：控制类顶格，宏调用跟随上下文
        if stripped.startswith("`"):
            kw = first_word(stripped[1:])
            if kw in PRAGMA:
                out.append(stripped)
            else:
                out.append(TAB * len(dims) + squeeze_inline(stripped))
            continue
        code = strip_comment(stripped).rstrip()
        kw = first_word(code)
        next_raw = lines[idx + 1] if idx + 1 < n else ""
        next_code = strip_comment(next_raw).strip() if next_raw.strip() else ""
        next_kw = first_word(next_code)
        tail_begin = code.endswith("begin") or kw == "begin"
        # 行首结束关键字 / '}'：先弹出一级
        if kw in LEAD_DEC or code.startswith("}"):
            if dims:
                dims.pop()
        out.append(TAB * len(dims) + squeeze_inline(stripped))
        # ---- 更新下一行层级 ----
        if tail_begin or kw in LEAD_INC:
            pop_single(dims)
            dims.append("b")
        elif kw in CTRL_NO_SEMI and not code.endswith(";"):
            # 无 begin 控制语句：下一行是 begin 时由 begin 入栈，否则单语句作用域
            if next_kw == "begin" or next_code.endswith("begin"):
                pass
            else:
                dims.append("s")
        elif kw == "else" and not code.endswith(";"):
            if next_kw == "begin" or next_code.endswith("begin"):
                pass
            else:
                dims.append("s")
        elif kw == "do" and not code.endswith(";"):
            dims.append("s")
        elif code.endswith("{") and kw == "typedef":
            pop_single(dims)
            dims.append("b")
        elif re.search(r":\s*$", code) and kw not in LEAD_INC and kw not in LEAD_DEC:
            dims.append("s")
        elif code.endswith("{") and kw != "typedef":
            pop_single(dims)
            dims.append("e")
        elif re.search(r"(?:&&|\|\||[+\-*/%&|^~<>=!?])\s*$", code):
            dims.append("e")
        if code.endswith(";"):
            pop_single(dims)
    return "\n".join(out) + "\n"


def main():
    patterns = [
        os.path.join(ROOT, "rtl", "*.sv"),
        os.path.join(ROOT, "tb", "*.sv"),
        os.path.join(ROOT, "uvm", "**", "*.sv"),
    ]
    files = []
    for pat in patterns:
        files.extend(glob.glob(pat, recursive=True))
    files = sorted(set(files))
    for f in files:
        with io.open(f, "r", encoding="utf-8") as fh:
            text = fh.read()
        new = reindent(text)
        if new != text:
            with io.open(f, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)
            print("reformatted: " + os.path.relpath(f, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
