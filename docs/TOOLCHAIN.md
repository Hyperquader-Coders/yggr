# TOOLCHAIN.md — toolchain & Odin API notes

`make check-toolchain` prints what is installed.

| Tool | Required |
|---|---|
| odin | ≥ `dev-2026-07a` (`os2` merged into `core:os`; see DECISIONS) |
| gtk4 | any 4.x |
| gtksourceview-5 | ≥ 5.10 (hover API) |
| foundry | optional — without it, use `YGGR_LSP_CMD` or the registry |
| python3 | for `scripts/fake_lsp.py` and the headless tests |
| gcc | for `src/ui/shim.c` |

## Odin API notes (current nightlies)

In `dev-2026-07` the **`os2` package is merged into `core:os`** — the classic
`os` moved to `core:os/old`, and `core:os/os2` no longer resolves. `src/lsp/`
and `src/ui/` alias `import os2 "core:os"` so `os2.*` call sites read the
same. The proc set: `process_start`, `process_wait`, `process_kill` (SIGKILL),
`process_terminate` (SIGTERM), `pipe`, `read`, `write`, `close`,
`stdin/stdout/stderr`, `Process`, `Process_Desc`, `Process_State`, `File`.

Other API specifics to verify against the installed core (ground truth):
- `get_env` requires an explicit allocator.
- `strings.split` / `strings.fields` take an allocator (default
  `context.allocator`).
- Outgoing JSON goes through the vendored OLS marshaller, not
  `json.marshal`: it omits nil-union fields and honors `json:"..."` tags.
- `process_wait(process, timeout)` timeout is a `time.Duration`;
  `TIMEOUT_INFINITE` and `General_Error.Timeout` exist.
- `filepath.abs` is realpath (opens the path); use `paths.abs` (`src/paths`) for
  the lexical form when building a URI/root.

## Commands

```sh
odin version
pkg-config --modversion gtk4 gtksourceview-5
foundry --version           # optional
python3 --version
```
