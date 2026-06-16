#!/usr/bin/env python3
"""Extract the matchit benchmark route set from the Rust source.

Reads benches/bench.rs from the matchit reference, finds the routes macro,
and emits routes.txt (with {p1}, {p2}, ...) and paths.txt (with literal
placeholders) so the OCaml and Rust benchmarks use identical inputs.
"""

import re
import sys

MATCHIT_BENCH = "/home/ribelo/projects/github/matchit/benches/bench.rs"


def extract_macro_body(path):
    with open(path, "r") as f:
        text = f.read()

    # Find the finish arm body: everything between the first '[' after
    # 'finish =>' and its matching ']'.
    start = text.find("(finish =>")
    if start == -1:
        raise RuntimeError("could not find finish arm")
    bracket = text.find("[", start)
    if bracket == -1:
        raise RuntimeError("could not find finish arm body")

    depth = 0
    for i in range(bracket, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[bracket + 1 : i]
    raise RuntimeError("unbalanced brackets")


def tokenize_concat(line):
    """Split concat!("a", $p1, "/b") into tokens."""
    line = line.strip()
    if not line.endswith(","):
        line = line + ","
    m = re.match(r"concat!\((.*)\),$", line, re.DOTALL)
    if not m:
        return None
    inner = m.group(1)
    tokens = []
    i = 0
    while i < len(inner):
        if inner[i] in " \t\n,":
            i += 1
        elif inner[i] == '"':
            j = inner.find('"', i + 1)
            if j == -1:
                raise RuntimeError("unterminated string")
            tokens.append(("str", inner[i + 1 : j]))
            i = j + 1
        elif inner[i] == "$":
            j = i + 1
            while j < len(inner) and (inner[j].isalnum() or inner[j] == "_"):
                j += 1
            tokens.append(("param", inner[i + 1 : j]))
            i = j
        else:
            raise RuntimeError(f"unexpected char {inner[i]!r}")
    return tokens


def build_route(tokens):
    parts = []
    for kind, value in tokens:
        if kind == "str":
            parts.append(value)
        elif kind == "param":
            parts.append("{" + value + "}")
    return "".join(parts)


def build_path(tokens, values):
    parts = []
    for kind, value in tokens:
        if kind == "str":
            parts.append(value)
        elif kind == "param":
            parts.append(values.get(value, value))
    return "".join(parts)


def main():
    body = extract_macro_body(MATCHIT_BENCH)
    lines = [line.strip() for line in body.split("\n") if line.strip()]

    # Literal values to substitute for each parameter when generating paths.
    param_values = {"p1": "123", "p2": "456", "p3": "789", "p4": "abc"}

    routes = []
    paths = []
    for line in lines:
        tokens = tokenize_concat(line)
        if tokens is None:
            continue
        routes.append(build_route(tokens))
        paths.append(build_path(tokens, param_values))

    with open("routes.txt", "w") as f:
        f.write("\n".join(routes) + "\n")
    with open("paths.txt", "w") as f:
        f.write("\n".join(paths) + "\n")

    print(f"wrote {len(routes)} routes and {len(paths)} paths")


if __name__ == "__main__":
    main()
