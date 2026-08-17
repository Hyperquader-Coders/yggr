# Third-party code

## OLS — Odin Language Server (github.com/DanielGavin/ols)

- **License:** MIT — full text in `third_party/ols/LICENSE`, © 2021 Daniel Gavin.
- **Commit pin:** `de6e2ec9a4cf6e090b4f40de7b2d1fe52dd861ce` (see
  `third_party/ols/VENDORED_COMMIT`).

Vendored because OLS is a production LSP
implementation in Odin that compiles against the current compiler, so its
framing and JSON marshalling replace the riskiest hand-written parts of this
project.

### `third_party/ols/` — pristine reference (DO NOT EDIT)

Unmodified upstream copies, kept solely so a future re-sync can diff against
them. Nothing in the build imports this directory.

```
third_party/ols/server/{reader,writer,response,types,marshal,unmarshal,requests}.odin
third_party/ols/common/{position,types,uri}.odin
```

### `src/lsp/vendor_ols/` — adapted, package `ols_lsp` (part of the build)

Each file carries the header
`// Adapted from OLS (github.com/DanielGavin/ols), MIT — see THIRD_PARTY.md`.
Adaptations were limited to: renaming `package server`/`package common` →
`package ols_lsp`, dropping unused imports and EOF-noise `log.error` calls,
and lifting only the pieces below (server request dispatch, the thread pool,
config handling and Odin-AST helpers were deliberately left behind).

| Adapted file | Source | What it provides / where it's used |
|---|---|---|
| `reader.odin` | `server/reader.odin` | `Reader` + `read_u8`/`read_until_delimiter`/`read_sized`. Byte/stream reader used by `transport.odin`. |
| `writer.odin` | `server/writer.odin` | Mutex-guarded `Writer` + `write_sized`. |
| `framing.odin` | `server/requests.odin` (`read_and_parse_header`) + `server/response.odin` (framed-write pattern) | `read_and_parse_header` and `write_frame`. `write_frame` holds the writer mutex across header+body (one contiguous frame) since our main and reader threads both write. |
| `marshal.odin` | `server/marshal.odin` | JSON marshaller that omits nil-union fields (optional LSP params) and honors `json:""` tags. Used by `client.odin:send`. |
| `uri.odin` | `common/uri.odin` | `file://` URI ↔ path helpers, used by `src/main.odin`. |

### Deliberate deviations (kept hand-written)

Rule 10 says to keep hand-written code only where the vendored code doesn't
cover it. Two pieces are kept and **not** replaced by OLS's equivalents:

- **`src/lsp/protocol.odin`** (MVP message structs) instead of
  `server/types.odin`. Upstream `types.odin` is server-oriented (full
  `ServerCapabilities`, semantic tokens, code actions, …) and its `common`
  dependencies pull in `core:odin/ast`/`tokenizer`. Our MVP needs only the
  six message families in SPEC §3; the compact hand-written subset is
  clearer and the vendored `marshal` handles the wire encoding.
- **`src/lsp/encoding.odin`** (line-level utf16↔utf8) instead of
  `common/position.odin`. Ours is covered by a dedicated acceptance-criterion
  test (SPEC §6.3) and has no Odin-AST dependency. `common/position.odin` is
  kept pristine for reference only.

**Re-sync procedure:** bump the clone, replace the files under
`third_party/ols/`, diff against the adapted copies in `src/lsp/vendor_ols/`,
and re-apply the package rename / import trimming.
