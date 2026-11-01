#!/usr/bin/env python3
"""Récepteur minimal des journaux envoyés par Lanterne (Réglages › Diagnostics).

À lancer sur une machine du réseau local (NAS, PC), par exemple :

    python3 scripts/log-receiver.py --port 8765 --dir ./lanterne-logs

ou dans Docker (Synology / Portainer) :

    docker run --rm -p 8765:8765 -v /volume1/docker/lanterne-logs:/logs \
        -v "$PWD/scripts/log-receiver.py:/app/r.py:ro" python:3.12-alpine \
        python /app/r.py --port 8765 --dir /logs

Puis saisir dans l'Apple TV : http://<ip-du-nas>:8765/logs
Aucune dépendance hors bibliothèque standard. N'exposez pas ce port sur Internet.
"""
import argparse
import datetime
import http.server
import os


def make_handler(directory: str, max_bytes: int):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > max_bytes:
                self.send_error(413, "taille invalide")
                return
            body = self.rfile.read(length)
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            path = os.path.join(directory, f"lanterne-{stamp}.log")
            with open(path, "wb") as f:
                f.write(body)
            print(f"{stamp} : {len(body)} octets reçus de {self.client_address[0]} → {path}", flush=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("ok\n".encode())

        def log_message(self, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--dir", default="./lanterne-logs")
    parser.add_argument("--max-mb", type=int, default=20)
    args = parser.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(args.dir, args.max_mb * 1024 * 1024))
    print(f"En écoute sur le port {args.port}, fichiers dans {os.path.abspath(args.dir)}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
