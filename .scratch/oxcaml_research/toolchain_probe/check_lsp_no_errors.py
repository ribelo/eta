import json
import os
import pathlib
import subprocess
import sys
import time


path = pathlib.Path(sys.argv[1]).resolve()
source = path.read_text()
uri = path.as_uri()
root_uri = pathlib.Path.cwd().resolve().as_uri()

proc = subprocess.Popen(
    ["ocamllsp", "-stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
next_id = 1


def send(message):
    data = json.dumps(message, separators=(",", ":")).encode()
    proc.stdin.write(b"Content-Length: " + str(len(data)).encode() + b"\r\n\r\n" + data)
    proc.stdin.flush()


def read_message(timeout=15):
    deadline = time.time() + timeout
    headers = {}
    line = b""

    while time.time() < deadline:
        ch = proc.stdout.read(1)
        if not ch:
            stderr = proc.stderr.read().decode(errors="replace")
            raise RuntimeError(f"ocamllsp closed stdout: {stderr}")
        line += ch
        if line.endswith(b"\r\n"):
            text = line[:-2].decode()
            line = b""
            if not text:
                break
            name, value = text.split(":", 1)
            headers[name.lower()] = value.strip()
    else:
        raise TimeoutError("timed out waiting for ocamllsp headers")

    length = int(headers["content-length"])
    return json.loads(proc.stdout.read(length))


def request(method, params):
    global next_id
    message_id = next_id
    next_id += 1
    message = {"jsonrpc": "2.0", "id": message_id, "method": method}
    if params is not None:
        message["params"] = params
    send(message)
    return message_id


def answer_server_request(message):
    if "id" in message and "method" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})


initialize_id = request(
    "initialize",
    {
        "processId": os.getpid(),
        "rootUri": root_uri,
        "workspaceFolders": [{"uri": root_uri, "name": "Effet-OxCaml"}],
        "capabilities": {},
    },
)

while True:
    message = read_message()
    if message.get("id") == initialize_id:
        break
    answer_server_request(message)

send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send(
    {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ocaml",
                "version": 1,
                "text": source,
            }
        },
    }
)

deadline = time.time() + 20
diagnostics = None
while time.time() < deadline:
    message = read_message(timeout=20)
    if message.get("method") == "textDocument/publishDiagnostics":
        params = message.get("params", {})
        if params.get("uri") == uri:
            diagnostics = params.get("diagnostics", [])
            break
    answer_server_request(message)

if diagnostics is None:
    raise TimeoutError("ocamllsp did not publish diagnostics for the mode probe")

errors = [
    item
    for item in diagnostics
    if not item.get("message", "").startswith("No config found for file")
]
if errors:
    print(json.dumps(errors, indent=2), file=sys.stderr)
    raise SystemExit(1)

shutdown_id = request("shutdown", None)
while True:
    message = read_message(timeout=5)
    if message.get("id") == shutdown_id:
        break
    answer_server_request(message)

send({"jsonrpc": "2.0", "method": "exit"})
proc.wait(timeout=5)
print("lsp diagnostics: []")
