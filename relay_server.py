#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, time

PORT = 8165
VERSION = "1.0.0"
CHATGPT_FILE = "/home/we6jbo/Learn-Ivrit-Recordings/battery_reports/chatgpt.txt"

STATE = {"signal": "ok", "payload": {}}
LAST_EXT_HEARTBEAT = 0
EXT_VERSION = None
LAST_REPORT_TS = 0

def window_active():
    now = time.time()
    start = time.mktime(time.strptime("2025-08-19 00:00:00", "%Y-%m-%d %H:%M:%S"))
    end   = time.mktime(time.strptime("2025-08-25 00:00:00", "%Y-%m-%d %H:%M:%S"))
    return start <= now < end

def maybe_report(component, msg=""):
    global LAST_REPORT_TS
    now = time.time()
    if not window_active(): 
        return
    if now - LAST_REPORT_TS < 30:  # throttle
        return
    LAST_REPORT_TS = now
    status = f"relay v{VERSION} ext_ver={EXT_VERSION or 'unknown'} sig={STATE['signal']} {msg}"
    try:
        with open(CHATGPT_FILE, "a") as f:
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
            f.write(f"{ts}\t{status}\n")
    except Exception:
        pass

class H(BaseHTTPRequestHandler):
    def _send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a): return

    def do_GET(self):
        if self.path == "/status":
            self._send(200, {"signal": STATE["signal"], "relay_version": VERSION})
            maybe_report("status")
        elif self.path == "/payload":
            self._send(200, STATE["payload"])
            maybe_report("payload")
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        global STATE, LAST_EXT_HEARTBEAT, EXT_VERSION
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try: data = json.loads(raw.decode())
        except: data = {}

        if self.path == "/signal":
            STATE["signal"] = "terminate-chrome"
            STATE["payload"] = data or {"action":"terminate-chrome"}
            self._send(200, {"ok":True})
            maybe_report("signal")
        elif self.path == "/clear":
            STATE.update({"signal":"ok","payload":{}})
            self._send(200, {"ok":True})
            maybe_report("clear")
        elif self.path == "/ext-heartbeat":
            LAST_EXT_HEARTBEAT = time.time()
            EXT_VERSION = data.get("version")
            ok = (EXT_VERSION == VERSION)
            self._send(200, {"ok": ok, "relay_version": VERSION})
            msg = "version_match" if ok else f"version_mismatch ext={EXT_VERSION}"
            maybe_report("ext-heartbeat", msg)
        else:
            self._send(404, {"error":"not found"})

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()

