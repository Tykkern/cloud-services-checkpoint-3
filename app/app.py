import os
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = os.environ.get("APP_VERSION", "dev")


def greeting(name):
    return f"Hello, {name}!"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"{greeting('KT3')} version={VERSION}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("", 8000), Handler).serve_forever()
