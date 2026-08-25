#!/usr/bin/env python3
# ============================================================================
# POE benchmark GUI 服务器（Python 标准库，无第三方依赖）
# - GET  /            → 前端单页（gui.html）
# - POST /api/run     → 拉起 run_verilator.sh（流量/线程/参数三组场景输入）
# - GET  /api/status  → 当前运行状态 + 日志尾部（前端轮询）
# - POST /api/cancel  → 终止当前运行
# - GET  /api/results → 历史结果列表（bench/results.json 持久化）
# 运行结束后从日志解析 BENCH_CSV 指标行 + 正确性检查（UVM_ERROR / idle）。
# 启动：python bench/gui_server.py  →  http://localhost:8765
# ============================================================================
import http.server
import json
import re
import subprocess
import threading
import time
import webbrowser
from pathlib import Path

BENCH = Path(__file__).resolve().parent
UVM_POE = BENCH.parent
SIM = UVM_POE / "sim"
GUI_HTML = BENCH / "gui.html"
LOG_DIR = BENCH / "logs"
RESULTS = BENCH / "results.json"
BASH = r"C:\msys64\usr\bin\bash.exe"
PORT = 8765

TRAFFIC_KEYS = ["RUN_US", "N_OH_PLANES", "OH_SLOTS", "N_X2X_PLANES",
                "X2X_SLOTS", "N_CH", "UART_MPPS"]
TAG_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")

STATE = {"running": False, "tag": None, "log": None, "proc": None,
         "started": None, "rc": None}
LOCK = threading.Lock()


def to_msys(p: Path) -> str:
    s = str(p)
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", s)
    return f"/{m.group(1).lower()}/{m.group(2).replace(chr(92), '/')}"


def load_results():
    if RESULTS.exists():
        try:
            return json.loads(RESULTS.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"runs": []}


def save_results(data):
    RESULTS.write_text(json.dumps(data, ensure_ascii=False, indent=1),
                       encoding="utf-8")


def parse_log(logpath: Path):
    """解析一次运行的指标：BENCH_CSV 行 + 正确性检查"""
    m = {}
    ok_log = False
    uvm_err = None
    idle = None
    try:
        text = logpath.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return m, False, None, None
    for line in text.splitlines():
        if line.startswith("BENCH_CSV"):
            for k, v in re.findall(r"(\w+)=([^\s]+)", line):
                m[k] = v
            ok_log = True
        if uvm_err is None:
            mm = re.search(r"UVM_ERROR\s*:\s*(\d+)", line)
            if mm:
                uvm_err = int(mm.group(1))
        mm = re.search(r"FINAL idle=(\d+)", line)
        if mm:
            idle = int(mm.group(1))
    return m, ok_log, uvm_err, idle


def run_worker(cmd, logpath, rid, cfg):
    try:
        with open(logpath, "w", encoding="utf-8") as lf:
            p = subprocess.Popen([BASH, "-lc", cmd], stdout=lf,
                                 stderr=subprocess.STDOUT)
            with LOCK:
                STATE["proc"] = p
            rc = p.wait()
        with LOCK:
            STATE["rc"] = rc
        metrics, ok_log, uvm_err, idle = parse_log(logpath)
        checks = {"log_ok": ok_log, "uvm_error": uvm_err, "idle": idle,
                  "ok": ok_log and uvm_err == 0 and idle == 64}
        data = load_results()
        data["runs"].append({"id": rid, "ts": time.strftime("%m-%d %H:%M:%S"),
                             "cfg": cfg, "metrics": metrics,
                             "checks": checks,
                             "log": str(logpath.relative_to(BENCH))})
        save_results(data)
    finally:
        with LOCK:
            STATE["running"] = False
            STATE["proc"] = None


def start_run(cfg):
    with LOCK:
        if STATE["running"]:
            return False, "已有场景在运行（共享 Verilator 构建目录，不支持并行）"
        tag = str(cfg.get("tag") or "bench").strip()
        if not TAG_RE.match(tag):
            return False, "tag 仅允许字母/数字/._-（≤32 字符）"
        STATE.update(running=True, tag=tag, rc=None, started=time.time())
    env = {"TESTNAME": "koa_smoke_test", "WAVE": "0", "BENCH_TAG": tag}
    for k in TRAFFIC_KEYS:
        v = cfg.get(k)
        if v not in (None, ""):
            env[k] = str(int(v))
    if cfg.get("seed") not in (None, ""):
        env["SEED"] = str(int(cfg["seed"]))
    if cfg.get("tpl_mask") not in (None, ""):
        env["TPL_MASK"] = str(int(cfg["tpl_mask"]))
    if cfg.get("meas_skip") not in (None, ""):
        env["MEAS_SKIP"] = str(int(cfg["meas_skip"]))
    if cfg.get("rw_mode") not in (None, ""):
        env["RW_MODE"] = str(int(cfg["rw_mode"]))
    LOG_DIR.mkdir(exist_ok=True)
    rid = time.strftime("%Y%m%d_%H%M%S") + "_" + tag
    logpath = LOG_DIR / f"{rid}.log"
    with LOCK:
        STATE["log"] = logpath
    assign = " ".join(f"{k}='{v}'" for k, v in env.items())
    cmd = f"cd '{to_msys(SIM)}' && {assign} ./run_verilator.sh"
    threading.Thread(target=run_worker, args=(cmd, logpath, rid, env),
                     daemon=True).start()
    return True, rid


def tail(path, n=30):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 16384))
            data = f.read().decode("utf-8", errors="replace")
        return data.splitlines()[-n:]
    except Exception:
        return []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else json.dumps(
            body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8"
                          if "json" in ctype or "html" in ctype else ""))
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, GUI_HTML.read_bytes(), "text/html")
        elif self.path == "/api/status":
            with LOCK:
                st = {"running": STATE["running"], "tag": STATE["tag"],
                      "log": str(STATE["log"]) if STATE.get("log") else None,
                      "elapsed": (time.time() - STATE["started"])
                      if STATE["started"] and STATE["running"] else None}
            st["tail"] = tail(STATE["log"]) if STATE.get("log") else []
            self._send(200, st)
        elif self.path == "/api/results":
            self._send(200, load_results())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        if self.path == "/api/run":
            ok, msg = start_run(body)
            self._send(202 if ok else 409, {"ok": ok, "msg": msg})
        elif self.path == "/api/cancel":
            with LOCK:
                p = STATE["proc"]
            if p:
                p.terminate()
                time.sleep(1)
                if p.poll() is None:
                    p.kill()
                self._send(200, {"ok": True, "msg": "已终止"})
            else:
                self._send(200, {"ok": False, "msg": "无运行中任务"})
        else:
            self._send(404, {"error": "not found"})


def main():
    if not Path(BASH).exists():
        print(f"错误：未找到 {BASH}（GUI 通过 MSYS2 bash 拉起 run_verilator.sh）")
        return
    url = f"http://localhost:{PORT}"
    print(f"POE benchmark GUI：{url}  （结果存 {RESULTS}）")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
