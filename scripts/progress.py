#!/usr/bin/env python3
"""在同一行上显示编译或安装进度，避免长时间没有任何输出。"""

import os
import re
import select
import subprocess
import sys
import time

def draw(pct, label, start, tty):
    pct = max(0, min(100, int(pct)))
    elapsed = int(time.time() - start)
    clock = f"{elapsed // 60:02d}:{elapsed % 60:02d}"
    label = label.replace("\n", " ")
    if len(label) > 42:
        label = label[:41] + "…"
    if not tty:
        return
    width = 24
    filled = round(pct * width / 100)
    bar = "█" * filled + "░" * (width - filled)
    line = f"{bar}  {clock}  {pct:3d}%  {label}"
    sys.stdout.write("\r\033[2K" + line)
    sys.stdout.flush()


def note(line, state):
    text = line.strip()
    name = None
    match = re.search(r"([A-Za-z0-9_+\-.]+\.(?:swift|m|mm|c|cc|cpp))", text)
    if match:
        name = match.group(1)

    if any(token in text for token in ("Resolve Package", "Prepare packages", "Compile plug-in", "GatherProvisioning")):
        state["pct"] = max(state["pct"], 8)
        state["label"] = "正在准备依赖"
    elif "SwiftCompile" in text or "CompileC " in text or "Compiling" in text:
        state["compiled"] += 1
        frac = min(1, state["compiled"] / max(state["estimate"], 1))
        state["pct"] = max(state["pct"], 12 + int(58 * frac))
        state["label"] = f"正在编译 {name}" if name else "正在编译"
    elif text.startswith("Ld ") or " clang " in text and " -o " in text:
        state["pct"] = max(state["pct"], 78)
        state["label"] = "正在链接"
    elif "CodeSign" in text:
        state["pct"] = max(state["pct"], 90)
        state["label"] = "正在签名"
    elif "Acquired tunnel" in text or "Enabling developer disk" in text:
        state["pct"] = max(state["pct"], 30)
        state["label"] = "正在连接手机"
    elif "App installed" in text or text.startswith("• bundleID"):
        state["pct"] = 100
        state["label"] = "安装完成"
    elif "BUILD SUCCEEDED" in text:
        state["pct"] = 100
        state["label"] = "编译完成"


def creep(state, mode):
    if mode == "install" and state["pct"] < 95:
        state["pct"] += 2
    elif mode == "compile" and state["label"] in ("正在链接", "正在签名") and state["pct"] < 96:
        state["pct"] += 1


def main():
    if len(sys.argv) < 4:
        sys.exit("用法：progress.py compile|install 日志文件 命令…")
    mode, log_path, *cmd = sys.argv[1:]
    tty = sys.stdout.isatty()
    state = {
        "pct": 1,
        "label": "正在编译" if mode == "compile" else "正在安装",
        "compiled": 0,
        "estimate": int(os.environ.get("PROGRESS_FILES", "80")),
    }
    start = time.time()
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        stream = proc.stdout
        while True:
            ready, _, _ = select.select([stream], [], [], 0.4)
            if ready:
                line = stream.readline()
                if line == "":
                    break
                log.write(line)
                log.flush()
                if mode == "compile" or mode == "install":
                    note(line, state)
            else:
                if proc.poll() is not None:
                    rest = stream.read()
                    if rest:
                        log.write(rest)
                        for line in rest.splitlines():
                            note(line, state)
                    break
                creep(state, mode)
            draw(state["pct"], state["label"], start, tty)
        code = proc.wait()
    if code == 0:
        draw(100, "完成", start, tty)
    if tty:
        sys.stdout.write("\n")
        sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(main())
