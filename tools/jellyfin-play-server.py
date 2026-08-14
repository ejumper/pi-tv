#!/usr/bin/env python3
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("JELLYFIN_PLAY_PORT", "8765"))
SCRIPT = os.path.expanduser(
    os.environ.get("JELLYFIN_PLAY_SCRIPT", "/home/tv/pi-tv/tools/jellyfin-play.sh")
)
COOLDOWN_SECONDS = float(os.environ.get("JELLYFIN_PLAY_COOLDOWN", "2.5"))

_last_run = 0.0
_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        self._handle()

    def do_GET(self) -> None:
        self._handle()

    def _handle(self) -> None:
        if self.path not in ("/jellyfin-play", "/jellyfin-play/"):
            self.send_response(404)
            self.end_headers()
            return

        global _last_run
        now = time.monotonic()
        with _lock:
            if now - _last_run < COOLDOWN_SECONDS:
                self.send_response(202)
                self.end_headers()
                return
            _last_run = now

        try:
            subprocess.Popen([SCRIPT], close_fds=True)
        except Exception:
            self.send_response(500)
            self.end_headers()
            return

        self.send_response(204)
        self.end_headers()

    def log_message(self, _format: str, *args) -> None:
        return


def main() -> None:
    if not os.path.isfile(SCRIPT):
        raise SystemExit(f"Script not found: {SCRIPT}")
    server = HTTPServer((HOST, PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
