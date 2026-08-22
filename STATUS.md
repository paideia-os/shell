# shell — status

**Wave:** R49 (Wave 1)
**Current milestone:** M2 (core implementation) — complete

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
  the happy path; `LR_ERR_BAD_BUF` on argv reject.
- `src/exec.pdx` (issue #3): `Exec` module — the exec-path skeleton.
  `exec_spawn_and_wait(argv, argv_count)` gates argv and returns
  `EX_STUB` (0xFFFFEC20) on the happy path; `EX_ERR_BAD_ARGV` on
  reject.

## M2 — core implementation (complete)

- `src/session.pdx` (issue #4, M2-001): `Session` module —
  `session_mint` (SS_RIGHTS_ALL) + `session_derive_subcap`
  (SS_RIGHTS_CHILD). 16-byte Cap wire matches libpdx-cap format.
  Strict-monotone-narrowing enforced at the rights-mask constant.
- `src/pipeline.pdx` (issue #5, M2-002): `Pipeline` module —
  `pipeline_plan` writes 2*(N-1) 16-byte Cap wire records for an
  N-stage pipeline (writer WRITE cap on stdout slot 1 + reader READ
  cap on stdin slot 0, sharing pipe id as target_ptr). Placeholder
  pipe ids at M2; real endpoint ids arrive with the M3 substrate.
- `src/exec.pdx` (issue #6, M2-003): `exec_narrow_child_caps` —
  cap narrowing at exec. Widen check `(child & ~parent) == 0` +
  intersection rights + parent's target_ptr. Reject codes
  EX_ERR_MISSING_CAP / EX_ERR_WIDENING / EX_ERR_SIDECAR_FULL.
  M1 skeleton `exec_spawn_and_wait` unchanged (sys_execve is M3+
  substrate).
- `src/pds.pdx` (issue #7, M2-004): `Pds` module — line-oriented
  parser for the `.pds` script header per
  `design/terminal/pds-format.md` §1. Second-byte lookahead
  dispatches shebang / capability / import / schema /
  requires-paideia / ascii. Six-slot `.bss` singleton records counts,
  flags, and body offset. Body dispatch reuses pipeline_plan +
  exec_narrow_child_caps.
- `src/history.pdx` (issue #8, M2-005): `History` module —
  `history_encode_record` builds the wire bytes for one HistoryEntry
  (24-byte header + cmd bytes + 0..7 zero pad; three qword-fused
  header fields for single-MOV atomicity). PdxFS write is M3+
  substrate; caps.decl gains `KIND_PDXFS_FILE(write)`.
- `src/shell.pdx`: stats table extended with `SH_ST_SESSIONS = 5`,
  `SH_ST_PIPELINES = 6`, `SH_ST_HISTORY = 7`.

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
| 0xFFFFEC24 | EX_ERR_MISSING_CAP| M2: child requires a KIND not in parent's cap set          |
| 0xFFFFEC25 | EX_ERR_WIDENING   | M2: child asks for rights parent does not hold             |
| 0xFFFFEC26 | EX_ERR_SIDECAR_FULL| M2: dst buffer too small for narrowed sidecar             |
| 0xFFFFEC30 | SS_ERR_BAD_DST    | Session.M2: dst == 0                                       |
| 0xFFFFEC31 | SS_ERR_BAD_ID     | Session.M2: session_id == 0                                |
| 0xFFFFEC32 | SS_ERR_BAD_SLOT   | Session.M2: slot >= 256                                    |
| 0xFFFFEC40 | PL_ERR_BAD_ARGS   | Pipeline.M2: dst == 0 or stages_count == 0                 |
| 0xFFFFEC41 | PL_ERR_TOO_MANY   | Pipeline.M2: stages_count > 8 (PL_MAX_STAGES)              |
| 0xFFFFEC42 | PL_ERR_DST_OVERFLOW | Pipeline.M2: dst_max_entries < 2*(stages_count-1)        |
| 0xFFFFEC50 | PDS_ERR_BAD_ARGS  | Pds.M2: buf == 0 or buf_len == 0                           |
| 0xFFFFEC51 | PDS_ERR_MALFORMED | Pds.M2: header line not recognised                         |
| 0xFFFFEC52 | PDS_ERR_OVERFLOW  | Pds.M2: too many caps/imports/schemas for one script       |
| 0xFFFFEC60 | HIST_ERR_BAD_ARGS | History.M2: dst == 0, dst_len == 0, or cmd_ptr NUL w/ len  |
| 0xFFFFEC61 | HIST_ERR_TOO_LONG | History.M2: cmd_len > 4096 (HIST_CMD_MAX)                  |
| 0xFFFFEC62 | HIST_ERR_TRUNCATED| History.M2: dst_len < required record size                 |

## Milestone rollup

| ID              | Title                                                            | State  |
|-----------------|------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + caps.decl (KIND_USER + KIND_TTY + KIND_IPC_ENDPOINT + InitCap seed) | LANDED |
| M1-002 (#2)     | line reader against KIND_TTY (skeleton via R41 semterm engine)   | LANDED |
| M1-003 (#3)     | minimal exec: sys_execve + wait + exit-code print (skeleton)     | LANDED |
| M2-001 (#4)     | KIND_SHELL_SESSION = 0x194 — mint at session start + derive sub-caps for children | LANDED |
| M2-002 (#5)     | pipeline: mint KIND_IPC_ENDPOINT per `\|`, splice into child stdin/stdout | LANDED |
| M2-003 (#6)     | caps environment propagation via libpdx-cap (narrow per callee caps.decl) | LANDED |
| M2-004 (#7)     | .pds script executor per design/terminal/pds-format.md           | LANDED |
| M2-005 (#8)     | ~/.history/ persistence via KIND_PDXFS_FILE(write) CoW journal   | LANDED |

## Upstream substrate (paideia-os, at HEAD 2026-08-21)

- `KIND_USER = 0x190` — landed at R48.M1-001 (`kind_user.pdx`).
- `KIND_IPC_ENDPOINT = 5` — landed at R20b (`kind.pdx:72`).
- `KIND_ELEVATE_CHANNEL = 0x191` — landed at R48b (`kind_elevate_channel.pdx`).
- `KIND_PDXFS_FILE = 0x195` — landed at R42 scaffold (`kind_pdxfs_file.pdx`,
  commits `411ad0e` and `2ff76d4`).
- `KIND_PDXFS_TXN = 0x196` — landed at R42 scaffold.
- `semterm engine + line_editor` — landed at R41.M4-002
  (`src/kernel/core/semterm/line_editor.pdx`, commits `92ee50c`,
  `251cd7c`).
- `InitCap sidecar` — landed at R20b.M4-001
  (`src/kernel/core/loader/init_caps.pdx`).

## Sibling libraries (all landed today)

- libpdx-cap.M2 — cap_pack_narrowed + cap_manifest_verify + cap_unpack_checked
- libpdx-semantic-pipe.M2 — passthrough + envelope
- libpdx-argv.M2 — typed flags + std vocab
- libpdx-audit.M2 — audit sender path
- libpdx-elevate.M2 — auto-approve + human-approve + Cap<> with lifetime

**Substrate gaps M2 continues to defer to M3:**

- `KIND_TTY` — not landed at HEAD; `kind_tty.pdx` does not exist in
  `src/kernel/core/cap/`. shell caps.decl names it symbolically; the
  provisional ordinal 0x196 in `SH_KIND_TTY` collides with
  `KIND_PDXFS_TXN` at the ordinal level — the smoke matrix at M4 will
  catch this drift and softarch pins the real KIND_TTY ordinal at
  substrate PR time (outside the 0x190–0x196 R42/R48 range).
- Userspace `sys_execve` / `sys_wait4` wrapper — the kernel side lands
  at R17; the M2 shell keeps `exec_spawn_and_wait` at the EX_STUB
  skeleton and pairs it with the standalone
  `exec_narrow_child_caps` helper. M3 wires them together.
- Userspace `sys_ipc_recv` / endpoint-mint wrapper — needed to turn
  M2's placeholder pipe ids in `pipeline_plan` into real endpoint
  ids. M3 substrate wiring.
- Userspace PdxFS-write path — needed to persist the bytes
  `history_encode_record` produces. M3 substrate wiring against
  `svc.pdxfs-journal`.
- Cross-repo linkage (shell → libpdx-cap symbols like
  `cap_pack_narrowed`) — deferred to M3 when the semantic-pipe /
  audit path also needs the cross-repo link resolved. Shell M2
  modules stay self-contained.

## Next

M3 — semantic-pipe passthrough + `libpdx-audit` integration +
tab-completion (`CommandCompletion[]` schema) + interactive prompt
schema (`ShellPromptRecord`). Depends on libpdx-semantic-pipe.M2
(passthrough shape) and libpdx-audit.M2 (both landed today; M3 can
open).
