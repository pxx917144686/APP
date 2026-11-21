#!/usr/bin/env python3
"""Minimal HTTP file server for testing the segmented IPA downloader.

Default mode: honors Range requests (206 Partial Content) like the App Store CDN.
--no-range: ignores the Range header and always returns 200 with the full body,
simulating a CDN without range support.
--throttle-ms=N: sleeps N ms after every 64KB chunk (per connection) to slow
transfers down — useful for cancel / pause / resume tests.

Usage: python3 RangeServer.py <port> <file> [--no-range] [--throttle-ms=N]
"""
import http.server
import os
import re
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18999
FILE = sys.argv[2] if len(sys.argv) > 2 else "big.bin"
NO_RANGE = "--no-range" in sys.argv
THROTTLE_MS = 0
PROBE_DELAY_MS = 0
STALL = "--stall" in sys.argv
STALL_AFTER_BYTES = 0
for arg in sys.argv:
    if arg.startswith("--throttle-ms="):
        THROTTLE_MS = int(arg.split("=")[1])
    if arg.startswith("--probe-delay-ms="):
        PROBE_DELAY_MS = int(arg.split("=")[1])
    if arg.startswith("--stall-after-bytes="):
        STALL_AFTER_BYTES = int(arg.split("=")[1])
SIZE = os.path.getsize(FILE)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if PROBE_DELAY_MS:
            import time
            time.sleep(PROBE_DELAY_MS / 1000.0)
        rng = self.headers.get("Range")
        start, end = 0, SIZE - 1
        partial = False
        if rng and not NO_RANGE:
            m = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else SIZE - 1
                elif m.group(2):  # suffix range bytes=-N
                    start = max(0, SIZE - int(m.group(2)))
                partial = True
        end = min(end, SIZE - 1)
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, SIZE))
        self.send_header("Content-Length", str(length))
        self.end_headers()
        import time
        if STALL:
            # 发完响应头后扣住连接不发数据，模拟"连接存活但传输停滞"
            time.sleep(600)
            return
        with open(FILE, "rb") as f:
            f.seek(start)
            remaining = length
            sent = 0
            while remaining > 0:
                chunk = f.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
                sent += len(chunk)
                if STALL_AFTER_BYTES and sent >= STALL_AFTER_BYTES:
                    # 发出部分数据后扣住连接，模拟传输中途停滞（看门狗测试）
                    time.sleep(600)
                    return
                if THROTTLE_MS:
                    time.sleep(THROTTLE_MS / 1000.0)

    def log_message(self, fmt, *args):
        sys.stderr.write("[server:%d] %s\n" % (PORT, fmt % args))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        print("serving %s (%d bytes) on :%d no_range=%s throttle=%dms" % (FILE, SIZE, PORT, NO_RANGE, THROTTLE_MS), flush=True)
        httpd.serve_forever()
