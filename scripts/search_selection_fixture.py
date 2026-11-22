#!/usr/bin/env python3
"""搜索结果点击回归的本地书源：一源立即返回，另一源等到 /release。

运行：python3 -I scripts/search_selection_fixture.py
配合 SearchStreamingSelectionUITests；只监听本机，不访问外站。
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Event, Lock
from urllib.parse import parse_qs, urlsplit
import json


class FixtureServer(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 18774), Handler)
        self.lock = Lock()
        self.gate = Event()
        self.pending = 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/reset":
            with self.server.lock:
                self.server.gate.set()
                self.server.gate = Event()
            self.reply("reset", "text/plain")
        elif url.path == "/release":
            with self.server.lock:
                self.server.gate.set()
            self.reply("released", "text/plain")
        elif url.path == "/state":
            with self.server.lock:
                pending = self.server.pending
            self.reply(json.dumps({"pending": pending}), "application/json")
        elif url.path == "/slow/search":
            with self.server.lock:
                gate = self.server.gate
                self.server.pending += 1
            # 请求预算，避免测试中断后留下无限等待；不靠延时决定 UI 状态。
            released = gate.wait(timeout=150)
            with self.server.lock:
                self.server.pending -= 1
            self.reply("<html><body></body></html>" if released else "fixture request timed out",
                       status=200 if released else 504)
        elif url.path == "/fast/search":
            page = parse_qs(url.query).get("page", ["1"])[0]
            books = ('<li class="book"><a href="/fast/book"><h3>PartialFixture</h3></a>'
                     '<span class="author">Fixture Author</span></li>') if page == "1" else ""
            self.reply(f"<html><body><ul>{books}</ul></body></html>")
        elif url.path == "/fast/book":
            self.reply('<html><body><h1>PartialFixture</h1><span class="author">Fixture Author</span>'
                       '<p class="intro">本地搜索导航测试。</p><a class="toc" href="/fast/toc">目录</a></body></html>')
        elif url.path == "/fast/toc":
            self.reply("<html><body><ul></ul></body></html>")
        else:
            self.reply("not found", "text/plain", status=404)

    def reply(self, body, content_type="text/html; charset=utf-8", status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # 暂停会取消慢源请求；明确记录客户端取消，不把它算成服务端成功。
            print("fixture: client cancelled response", flush=True)

    def log_message(self, format, *args):
        # 不记录请求 query 或正文。
        return


if __name__ == "__main__":
    with FixtureServer() as server:
        print("search selection fixture ready: localhost:18774", flush=True)
        server.serve_forever()
