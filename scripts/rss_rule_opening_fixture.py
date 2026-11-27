#!/usr/bin/env python3
"""仅在 loopback 提供 RSSRuleListOpeningUITests 的合成列表和封面。"""

import base64
import json
import struct
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit


def sample_cover():
    """纯色 PNG，方便在模拟器截图上确认显示的是解码图片，不是占位图。"""
    def chunk(kind, value):
        return (struct.pack(">I", len(value)) + kind + value
                + struct.pack(">I", zlib.crc32(kind + value)))

    row = b"\0" + bytes((12, 236, 112)) * 24
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 24, 24, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(row * 24)) + chunk(b"IEND", b""))
    return b"data:image/png;base64," + base64.b64encode(png)


class Handler(BaseHTTPRequestHandler):
    catalog_requests = 0

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/gate/categories":
            self.reply(url.path, 200, "<a href='/gate/list'>最新</a>")
        elif url.path == "/gate/list":
            if query != {"mode": ["async"], "from": ["1"]} or self.headers.get("X-RSS-Fixture") != "local":
                self.reply(url.path, 400, "Unexpected fixture request")
                return
            Handler.catalog_requests += 1
            status, title = (403, "不应显示的拒绝页条目") if Handler.catalog_requests == 1 else (200, "本机列表重试条目")
            self.reply(url.path, status, f"<div class='entry'><a href='/gate/article'>{title}</a></div>")
        elif url.path == "/stream/list":
            page = query.get("page", [""])[0]
            if not page.isascii() or not page.isdecimal() or not 0 <= int(page) <= 1500:
                self.reply(url.path, 400, "Expected the evaluated random page")
                return
            body = json.dumps({"rescont": {"data": [
                {"id": "one", "title": "本机随机分类条目", "coverbase64": {"url": "/stream/cover"}}
            ]}}, ensure_ascii=False)
            self.reply(url.path, 200, body, "application/json; charset=utf-8")
        elif url.path == "/stream/cover":
            self.reply(url.path, 200, sample_cover(), "text/plain")
        elif url.path == "/icon.png":
            self.reply(url.path, 204, b"")
        else:
            self.reply("unknown-route", 404, "Not found")

    def reply(self, route, status, body, content_type="text/html; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(f"GET {route} {status}", flush=True)

    def log_message(self, *_):
        # 只记录预定义路由和状态，不输出请求参数或头。
        pass


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        print(f"port={server.server_port}", flush=True)
        server.serve_forever()
