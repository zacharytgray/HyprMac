#!/usr/bin/env python3
"""Serve the fake update feed that build-update-test.sh makes.

Run it from the feed folder on the Mac under test. It listens on 127.0.0.1
only. --appcast-delay holds the appcast back, so the check that Sparkle
starts at launch finishes late and takes the scheduled-check path.
"""
import argparse
import http.server
import os
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--appcast-delay", type=float, default=0)
    args = parser.parse_args()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0].endswith("appcast.xml"):
                time.sleep(args.appcast_delay)
            super().do_GET()

    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
