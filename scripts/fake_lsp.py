#!/usr/bin/env python3
"""fake_lsp.py — minimal LSP server for headless tests (stdlib only).

Answers: initialize (utf-8 positions), hover, completion, formatting,
shutdown. Emits one canned diagnostic after every didOpen/didChange.
Usage: YGGR_LSP_CMD="python3 scripts/fake_lsp.py" yggr file.go
"""
import json, sys

def read_msg(stdin):
    length = None
    while True:
        line = stdin.readline()
        if not line:
            return None
        if line.strip() == b"":
            break
        k, _, v = line.partition(b":")
        if k.lower() == b"content-length":
            length = int(v.strip())
    return json.loads(stdin.read(length))

def send(obj):
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()

def diag(uri, version):
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "version": version, "diagnostics": [{
              "range": {"start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 4}},
              "severity": 1, "source": "fake", "message": "fake error"}]}})

def main():
    stdin = sys.stdin.buffer
    while True:
        msg = read_msg(stdin)
        if msg is None:
            return
        m, i = msg.get("method"), msg.get("id")
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": i, "result": {"capabilities": {
                "positionEncoding": "utf-8",
                "textDocumentSync": 1,
                "hoverProvider": True,
                "completionProvider": {"triggerCharacters": ["."]},
                "documentFormattingProvider": True}}})
        elif m in ("textDocument/didOpen", "textDocument/didChange"):
            td = msg["params"]["textDocument"]
            diag(td["uri"], td.get("version", 0))
        elif m == "textDocument/hover":
            send({"jsonrpc": "2.0", "id": i, "result": {"contents": {
                "kind": "markdown", "value": "**fake** hover with `code`"}}})
        elif m == "textDocument/completion":
            send({"jsonrpc": "2.0", "id": i, "result": [
                {"label": "Println", "kind": 3, "detail": "func(a ...any)",
                 "insertText": "Println"},
                {"label": "Printf", "kind": 3, "detail": "func(f string, a ...any)",
                 "insertText": "Printf"}]})
        elif m == "textDocument/formatting":
            send({"jsonrpc": "2.0", "id": i, "result": [
                {"range": {"start": {"line": 0, "character": 0},
                           "end": {"line": 0, "character": 0}},
                 "newText": "// formatted\n"}]})
        elif m == "shutdown":
            send({"jsonrpc": "2.0", "id": i, "result": None})
        elif m == "exit":
            return
        elif i is not None:  # unknown request: must answer
            send({"jsonrpc": "2.0", "id": i,
                  "error": {"code": -32601, "message": "not implemented"}})

if __name__ == "__main__":
    main()
