#!/usr/bin/env python3
import csv
import os
import socket
import ssl
import sys
import time


def now_us() -> int:
    return time.time_ns() // 1000


def read_until_headers(sock, buffer: bytes, timeout_s: float):
    deadline = time.monotonic() + timeout_s
    while b"\r\n\r\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("response headers")
        sock.settimeout(remaining)
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("response headers")
        buffer += chunk
    head, rest = buffer.split(b"\r\n\r\n", 1)
    return head, rest


def parse_headers(head: bytes):
    lines = head.decode("iso-8859-1").split("\r\n")
    status = int(lines[0].split(" ", 2)[1])
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            headers.setdefault(name.strip().lower(), []).append(value.strip())
    return status, headers


def content_length(headers) -> int:
    values = headers.get("content-length", [])
    if not values:
        return 0
    return int(values[-1])


def read_exact_body(sock, buffer: bytes, length: int, timeout_s: float):
    deadline = time.monotonic() + timeout_s
    while len(buffer) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("response body")
        sock.settimeout(remaining)
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("response body")
        buffer += chunk
    return buffer[:length], buffer[length:]


def request_bytes(method: str, path: str, host: str, body: bytes) -> bytes:
    headers = [
        f"{method} {path} HTTP/1.1",
        f"Host: {host}",
        "Connection: keep-alive",
        "User-Agent: eta-h1-gap-client",
        "Accept: */*",
    ]
    if method == "POST" or body:
        headers.append(f"Content-Length: {len(body)}")
        headers.append("Content-Type: application/octet-stream")
    return ("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body


def connect(host: str, port: int, timeout_s: float):
    raw = socket.create_connection((host, port), timeout=timeout_s)
    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    local_port = raw.getsockname()[1]
    ca_file = os.environ.get("ETA_H1_GAP_TLS_CA_FILE")
    if ca_file:
        ctx = ssl.create_default_context(cafile=ca_file)
        sock = ctx.wrap_socket(raw, server_hostname="localhost")
    else:
        sock = raw
    return sock, local_port


def run(host: str, port: int, requests: int, out_path: str, path: str) -> None:
    method = os.environ.get("ETA_H1_GAP_METHOD", "POST").upper()
    body_bytes = int(os.environ.get("ETA_H1_GAP_BODY_BYTES", "1024") or "1024")
    timeout_s = float(os.environ.get("ETA_H1_GAP_TIMEOUT", "30") or "30")
    expected_bytes = int(
        os.environ.get("ETA_H1_GAP_EXPECTED_RESPONSE_BYTES", str(body_bytes))
        or str(body_bytes)
    )
    body = b"x" * body_bytes
    request = request_bytes(method, path, "localhost", body)
    sock, local_port = connect(host, port, timeout_s)
    buffer = b""
    rows = []
    try:
        for index in range(1, requests + 1):
            error = ""
            status = -1
            received = 0
            t0 = now_us()
            t1 = -1
            t2 = -1
            t3 = -1
            try:
                sock.sendall(request)
                t1 = now_us()
                head, buffer = read_until_headers(sock, buffer, timeout_s)
                t2 = now_us()
                status, headers = parse_headers(head)
                length = content_length(headers)
                body_data, buffer = read_exact_body(sock, buffer, length, timeout_s)
                received = len(body_data)
                t3 = now_us()
                if status != 200:
                    error = f"status:{status}"
                elif received != expected_bytes:
                    error = f"bytes:{received}"
            except Exception as exn:
                error = type(exn).__name__ + ":" + str(exn)
                t3 = now_us()
            rows.append(
                {
                    "index": index,
                    "local_port": local_port,
                    "t0_us": t0,
                    "t1_us": t1,
                    "t2_us": t2,
                    "t3_us": t3,
                    "status": status,
                    "bytes": received,
                    "error": error,
                }
            )
            if error:
                break
    finally:
        try:
            sock.close()
        except Exception:
            pass

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "index",
                "local_port",
                "t0_us",
                "t1_us",
                "t2_us",
                "t3_us",
                "status",
                "bytes",
                "error",
            ],
            delimiter="\t",
        )
        writer.writeheader()
        writer.writerows(rows)


def usage() -> None:
    print(
        f"usage: {sys.argv[0]} HOST PORT REQUESTS OUT.tsv [PATH]",
        file=sys.stderr,
    )
    raise SystemExit(2)


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        usage()
    run(
        sys.argv[1],
        int(sys.argv[2]),
        int(sys.argv[3]),
        sys.argv[4],
        sys.argv[5] if len(sys.argv) == 6 else "/echo",
    )
