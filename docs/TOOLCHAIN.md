# TOOLCHAIN.md — toolchain & Odin API notes

Reference environment: Linux Mint (kernel 6.17, Ubuntu 24.04 base).

| Tool | Required | Found | OK |
|---|---|---|---|
| odin | ≥ dev-2025-01 | `dev-2026-07-nightly:819fdc7` (mise install `dev-2026-07a`) | ✅ |
| gtk4 | any 4.x | 4.14.5 | ✅ |
| gtksourceview-5 | ≥ 5.10 (hover API) | 5.12.0 | ✅ |
| foundry | optional | NOT FOUND | ⚠️ soft — use `YGGR_LSP_CMD` |
| python3 | for fake_lsp / tests | 3.14.6 | ✅ |
| gcc | for shim.c | 13.3.0 | ✅ |

## Odin API notes (current nightlies)

In `dev-2026-07` the **`os2` package is merged into `core:os`** — the classic
`os` moved to `core:os/old`, and `core:os/os2` no longer resolves. `src/lsp/`
aliases `import os2 "core:os"` so `os2.*` call sites read the same. The proc
set: `process_start`, `process_wait`, `process_kill` (SIGKILL),
`process_terminate` (SIGTERM), `pipe`, `read`, `write`, `close`,
`stdin/stdout/stderr`, `Process`, `Process_Desc`, `Process_State`, `File`.

Other API specifics to verify against the installed core (ground truth):
- `get_env` requires an explicit allocator (`get_env_alloc`).
- `strings.split` takes an allocator (defaults to `context.allocator`).
- `json.marshal(v, opt, allocator)` returns `(data, err)`; respects
  `json:"..."` field tags.
- `process_wait(process, timeout)` timeout is a `time.Duration`;
  `TIMEOUT_INFINITE` and `General_Error.Timeout` exist.
- `filepath.abs` is realpath (opens the path); use `amber:afs.abs` for the
  lexical form when building a URI/root.

## Commands

```sh
odin version
pkg-config --modversion gtk4 gtksourceview-5
foundry --version           # optional
python3 --version
```
