# shell — status

**Wave:** R49 (Wave 1)
**Current milestone:** M1 (design + skeleton) — complete

See `design/tooling/r49-r50-plan.md` §5.2 in paideia-os for the full
breakdown.

## M1 — design + skeleton (complete)

- `src/shell.pdx` (issue #1): top-level `Shell` module — KIND ordinal
  mirrors (SH_KIND_USER / SH_KIND_TTY / SH_KIND_IPC_ENDPOINT /
  SH_KIND_SHELL_SESSION / SH_KIND_PDXFS_FILE / SH_KIND_ELEVATE_CHANNEL),
  the 0xFFFFECxx return-code band, and the eight-slot `_shell_stats`
  counter table with `shell_reset` / `shell_note` / `shell_stat`.
- `caps.decl` (issue #1): the four caps the shell holds at exec
  (KIND_USER read, KIND_TTY write, KIND_IPC_ENDPOINT mint,
  KIND_SHELL_SESSION mint) plus the three semantic-pipe schemas the
  shell emits (ShellPromptRecord, CommandCompletion, ShellCommandRecord).
- `design/architecture.md` (issue #1): full M1 spec covering all three
  modules plus the 0xFFFFECxx band, the paideia-as conformance
  checklist, and the M4 test matrix.
- `src/line_reader.pdx` (issue #2): `LineReader` module — the
  interactive line-reader skeleton. `line_reader_read_line(buf,
  buf_len)` gates the buffer and returns `LR_STUB` (0xFFFFEC10) on
  the happy path; `LR_ERR_BAD_BUF` on argv reject. Bumps
  `SH_ST_PROMPTS` / `SH_ST_ERRORS`. M2 replaces the LR_STUB tail
  with the sys_read + semterm line-editor dispatch loop.
- `src/exec.pdx` (issue #3): `Exec` module — the exec-path skeleton.
  `exec_spawn_and_wait(argv, argv_count)` gates argv and returns
  `EX_STUB` (0xFFFFEC20) on the happy path; `EX_ERR_BAD_ARGV` on
  reject. Bumps `SH_ST_SPAWNS` / `SH_ST_ERRORS`. M2 replaces the
  EX_STUB tail with the real sys_execve + sys_wait4 dispatch after
  libpdx-cap.M2 lands cap narrowing and libpdx-argv.M2 lands the
  child-side argv walker.

## Return-code band 0xFFFFECxx

| Code       | Name              | Meaning                                                    |
|------------|-------------------|------------------------------------------------------------|
| 0xFFFFEC00 | SH_OK             | General success (unused at M1)                             |
| 0xFFFFEC10 | LR_STUB           | LineReader.M1: validated, no live read yet                 |
| 0xFFFFEC11 | LR_ERR_BAD_BUF    | buf == 0 or buf_len == 0                                   |
| 0xFFFFEC12 | LR_ERR_TTY_UNBOUND| M2+: KIND_TTY(read) missing from caller                    |
| 0xFFFFEC13 | LR_ERR_EOF        | M2+: sys_read on TTY returned 0 unexpectedly               |
| 0xFFFFEC20 | EX_STUB           | Exec.M1: validated, no live spawn yet                      |
| 0xFFFFEC21 | EX_ERR_BAD_ARGV   | argv == 0 or argv_count == 0                               |
| 0xFFFFEC22 | EX_ERR_EXECVE_FAIL| M2+: sys_execve refused                                    |
| 0xFFFFEC23 | EX_ERR_WAIT_FAIL  | M2+: sys_wait4 refused                                     |

## Milestone rollup

| ID              | Title                                                            | State  |
|-----------------|------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + caps.decl (KIND_USER + KIND_TTY + KIND_IPC_ENDPOINT + InitCap seed) | LANDED |
| M1-002 (#2)     | line reader against KIND_TTY (skeleton via R41 semterm engine)   | LANDED |
| M1-003 (#3)     | minimal exec: sys_execve + wait + exit-code print (skeleton)     | LANDED |

## Upstream substrate (paideia-os, at HEAD 2026-08-21)

- `KIND_USER = 0x190` — landed at R48.M1-001 (`kind_user.pdx`).
- `KIND_IPC_ENDPOINT = 5` — landed at R20b (`kind.pdx:72`).
- `KIND_ELEVATE_CHANNEL = 0x191` — landed at R48b (`kind_elevate_channel.pdx`).
- `KIND_PDXFS_FILE = 0x195` — landed at R42 scaffold (`kind_pdxfs_file.pdx`,
  commits `411ad0e` and `2ff76d4`).
- `semterm engine + line_editor` — landed at R41.M4-002
  (`src/kernel/core/semterm/line_editor.pdx`, commits `92ee50c`,
  `251cd7c`).
- `InitCap sidecar` — landed at R20b.M4-001
  (`src/kernel/core/loader/init_caps.pdx`).

**Substrate gaps M1 defers to M2:**

- `KIND_TTY` — not landed at HEAD; `kind_tty.pdx` does not exist in
  `src/kernel/core/cap/`. shell M1 uses a provisional ordinal 0x196
  in `SH_KIND_TTY` (`src/shell.pdx`) and names it symbolically in
  `caps.decl`; the M4 smoke matrix will catch any drift when the
  real ordinal lands.
- Userspace `sys_execve` / `sys_wait4` wrapper — the kernel side lands
  at R17 (`src/kernel/core/syscall/handlers/`), but a userspace
  binary calling it needs an M2 assembly wrapper the shell repo will
  ship alongside the pipeline mint.

## Next

M2 — the pipeline substrate. Depends on libpdx-cap.M2 (cap narrowing
at exec) and libpdx-argv.M2 (children's argv). Lands
KIND_SHELL_SESSION = 0x194 minted at session start, mints one
KIND_IPC_ENDPOINT per `|`, replaces the LR_STUB and EX_STUB tails
with live substrate calls, adds .pds script executor per
`design/terminal/pds-format.md`, and adds `~/.history/` persistence
via KIND_PDXFS_FILE(write) CoW journal.
