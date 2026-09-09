# shell — CHANGELOG

All notable changes to this project. The format follows Keep a
Changelog conventions; the project follows Semantic Versioning per
`design/tooling/plan.md` §6.

## Unreleased — Syscall floor extension: sys_yield (#47)

Extends ENH-001's `Syscall` module with `SYS_YIELD = 5` + a
matching arity-0 `sys_yield` wrapper. This is the precondition
`design/architecture.md` §3.3 named for the KIND_TTY(read) seam
migration (#46 step 3): once the seam swap flips
`lr_read_one_byte` to `sys_cap_invoke(tty_cap_slot, TTY_OP_READ)`,
the `TTY_READ_EMPTY` (0xFFFFEC35) branch will wrap in a
`sys_yield; jmp poll_top` loop so the caller's blocking-read
contract is preserved. No in-tree caller yet; the floor addition
is landed ahead of #46 per ENH-001's floor-first / consumer-later
staging pattern.

### Added

- `src/syscall.pdx` `SYS_YIELD : u64 = 5` — SC+ ID reserved for
  `sys_yield`. Provenance is repo-side (`design/architecture.md`
  §3.3): paideia-os `design/user/syscall-table.md` carries no row
  at ID 5 today, so the shell reserves the shell-visible slot
  ahead of the kernel dispatch wiring. Kernel-side substrate
  (`src/kernel/core/sched/yield.pdx` `sched_yield`) already
  exists and is reachable via KIND_SCHED_CTX OP_YIELD (op_code=5,
  `src/kernel/core/cap/kind_sched.pdx`); wiring
  `dispatch.pdx` to a direct sysno-5 arm is the paired paideia-os
  landing #46 depends on.
- `src/syscall.pdx` `sys_yield : () -> u64 !{sysreg} @{sched}` —
  arity-0 wrapper (`mov rax, 5; syscall; ret`). Effect and
  capability set match the R13 legacy `sys_yield` and the
  kernel-side KIND_SCHED_CTX OP_YIELD posture: `sysreg` for
  SYSCALL itself, `@{sched}` because the handler tail-calls into
  `sched_pick_next` / `sched_switch`. No `mem` effect (yield
  touches no user memory). Leaf function; SYSCALL clobbers
  rcx/r11 (both SysV caller-save, harmless).

### Changed

- `src/syscall.pdx` module header — updated the "nine SC+ IDs"
  exit criterion to "ten SC+ IDs" and refreshed the sysno-list
  block comment to note SC+ ID 5's provenance (repo-side
  `design/architecture.md` §3.3, ahead of the paideia-os
  `syscall-table.md` row that a paired kernel-side landing will
  add).

### Unblocks

- shell#46 step 3: the KIND_TTY(read) seam swap inside
  `lr_read_one_byte` can now use `Syscall.sys_yield` verbatim
  without a further shell-side floor extension.
## Unreleased — #45: shell_repl_step full stage walk

`shell_repl_step` (`src/shell.pdx`) now iterates every stage the
parser produced. The ENH-006 (#33) landing body ran only
`_pr_stages[0]` and silently dropped `_pr_stages[1..]` -- a two-
stage line like `ls | cat` ran `ls` alone and `| cat` disappeared
without an error even though the parser had already emitted a
correct two-stage table (verified by #30's `tsm_case_pipeline`
golden). #45 replaces the stage[0]-only body with a loop over
`[0, _pr_stage_count)` that per stage resolves the argv slice,
tries `dispatch_line` first, and on `BI_MISS` derives the child
sub-cap + calls `exec_spawn_and_wait`. The pipeline's return is
the last stage's rc, matching the POSIX pipeline exit-code
convention.

Pipe-fd wiring (`sys_pipe` + per-stage stdin/stdout dup) and true
parallel per-stage execution stay deferred until `sys_fork`
(SC+56) lands under shell#44. Without fork, `exec_spawn_and_wait`
either succeeds and never returns (kernel replaces the shell
image) or fails with `EX_ERR_EXECVE_FAIL` (parent continues to
the next stage). Post-#44 the fingerprint `ls | cat` produces
piped output; #45's fingerprint today is `SH_ST_STAGES bumps by
N for an N-stage line`, verified by the new
`tshm_case_repl_pipe_stages` case.

### Added

- `src/shell.pdx` `SH_ST_STAGES` (slot 11) — one bump per
  attempted stage inside `shell_repl_step`. Extends the shell
  stats table from 11 to 12 populated slots; slots 12..15 stay
  reserved for M4/M5. `shell_reset`'s 0..16 zero-loop already
  covers the new slot without a bound change.
- `tests/test_shell_main.pdx` `_tshm_arg_cd_pipe_cd` fixture
  (`"cd | cd\0"`, 8 bytes) + `tshm_case_repl_pipe_stages` case
  in the `0xFFFFED8A` fail sub-band. Asserts the two-stage line
  returns `BI_ERR_CD_NO_ARG` (last stage wins) AND
  `SH_ST_STAGES` bumps by exactly 2. Wired into `tshm_run_all`
  after `tshm_case_repl_cd_noarg`.

### Changed

- `src/shell.pdx` `shell_repl_step` — body now walks
  `[0, _pr_stage_count)` instead of executing only stage[0].
  Register plan: `r12` repurposed post-parse from `line_ptr` to
  the stage index `i`; `r13` from `line_len` to `stage_count`;
  `rbx` from `argc` to `last_rc`; per-stage `argc` moves to a
  `[rsp + 0]` stack slot (prologue widens `sub rsp, 8` to
  `sub rsp, 16`; 56-byte prologue keeps `rsp % 16 == 0`).
- `src/shell.pdx` slot-map comment + `SH_ST_STAGES` constant
  block extended; the ENH-006 top-of-section header note now
  points at the shell_repl_step §FORK-GAP + PIPE-WIRING
  DEFERRALS block for what is / is not covered by #45.
- `tests/test_shell_main.pdx` `tshm_reset` populates the new
  `_tshm_arg_cd_pipe_cd` fixture with the same `mov rax, <lit>;
  mov_b [r10 + N], rax` idiom the other argv-string fixtures
  use; case-listing docstrings + `0xFFFFED8x` fail-code table +
  case count in `tshm_run_all` all bumped from 10 to 11.

## Unreleased — ENH-008: history persist to disk (#35)

`history_encode_record`'s wire bytes now reach the filesystem. The
shell opens `~/.history/<session>-<ts>.pdxhist` at startup via
`sys_open(O_WRONLY|O_CREAT|O_APPEND, 0644)` (guarded by
`--no-history`), drains the encoded HistoryEntry ring to disk via a
`sys_write` partial-write retry loop after every REPL step, and
closes the fd on EOF. The R106.M1 persistent-home substrate
(paideia-os #2228) is what the writer sys_opens into. Runtime
persistence proof (reboot-across boundary) is a paideia-os boot
smoke; the shell repo's local tests verify the writer path
assembles correctly against the encoder's golden bytes.

### Added

- `src/history.pdx` `HI_OK` (0) + `HI_ERR_OPEN_FAIL` (0xFFFFEC63)
  + `HI_ERR_WRITE_FAIL` (0xFFFFEC64) + `HI_ERR_CLOSE_FAIL`
  (0xFFFFEC65) + `HI_ERR_PATH_TOO_LONG` (0xFFFFEC66). Extends the
  History module's own 0xFFFFEC6x sub-band (the initial issue text
  proposed 0xFFFFED0x, but that band belongs to TestCapsNarrow —
  aliasing a test-driver's return with a shell-layer sentinel would
  corrupt the boot-time smoke's decoder; the "next free above line
  reader's 0xFFFFEC1x" alternative in the same issue is the
  architecturally-correct choice, and every occupied sub-band except
  6x is fully allocated).
- `src/history.pdx` `hi_home_path` — 70-byte placeholder home path
  literal `/home/deadbeef00...000000` mirroring paideia-os
  `FounderConstants::fc_placeholder_home_path` (R106.M1 / #2228).
  The shell satellite is standalone and does not link the monorepo's
  `founder_constants.pdx`; the byte pattern is duplicated with a
  docstring cross-reference. R108.M2 will retire the placeholder in
  the monorepo with a paired update here.
- `src/history.pdx` `hi_history_dir` (`/.history/`) + `hi_ext`
  (`.pdxhist\0`) — the fixed path components appended to the home
  path.
- `src/history.pdx` `_hi_path_buf : [u8; 256]` — .bss scratch for
  the composed sys_open path. Aligned @16 for a future SIMD-widened
  memcpy.
- `src/history.pdx` `history_format_u64_dec(value, out_buf) -> u64`
  — leaf helper writing a u64 as decimal ASCII to a caller-owned
  buffer. Verbatim divide-by-10 loop shape from `cp_print_u64_dec`,
  but emits to a buffer rather than sys_debug_puts.
- `src/history.pdx` `history_format_path(session_id, ts, out_buf,
  out_cap) -> u64` — composes the per-session path bytes
  `/home/<placeholder-fp>/.history/<session>-<ts>.pdxhist\0` into
  the caller's buffer. Returns the length (including NUL) or
  `HI_ERR_PATH_TOO_LONG` on out_cap overflow. Cap gate requires
  `out_cap >= 130` (u64::MAX worst case).
- `src/history.pdx` `history_open_file(session_id, ts) -> u64` —
  composes the path into `_hi_path_buf` and calls
  `sys_open(O_WRONLY|O_CREAT|O_APPEND, 0644)`. Returns fd (>=0) or
  `HI_ERR_OPEN_FAIL` (sign bit set so a caller's
  `cmp rax, 0; jl` treats it as invalid fd).
- `src/history.pdx` `history_persist_flush(fd) -> u64` — drains
  `Shell::_sm_hist_buf[0.._sm_hist_used)` to fd via a partial-write
  retry loop, then resets `_sm_hist_used = 0` on success. Skips
  silently on `--no-history`, on an empty ring, and on an invalid
  fd. Refuses with `HI_ERR_WRITE_FAIL` when `sys_write` returns
  `<= 0`.
- `src/history.pdx` `history_close_file(fd) -> u64` — thin
  `sys_close` wrapper. No-ops on an invalid fd.
- `src/shell.pdx` `_sm_hist_fd : u64` — .bss slot for the history
  fd. Populated at shell_main startup via `history_open_file`
  (guarded by `--no-history`), consumed by
  `history_persist_flush` after every REPL step, and closed by
  `history_close_file` on EOF.
- `tests/test_history.pdx` `TestHistory` module. Seven offline
  cases in the `0xFFFFEDAx` fail band:
  `thi_case_format_u64_zero`, `thi_case_format_u64_multi`,
  `thi_case_open_path_format` (verifies the composed bytes for
  session=1, ts=42 at every region boundary + NUL terminator),
  `thi_case_flush_no_history`, `thi_case_flush_ring_empty`,
  `thi_case_flush_fd_invalid`, `thi_case_close_fd_invalid`. Umbrella
  `thi_run_all`. The runtime write matrix (real sys_open + sys_write
  + sys_close against a live filesystem) is deferred to the
  paideia-os boot smoke — the shell repo cannot boot itself and
  paideia-as does not carry conditional compilation for a mock-shim
  redirect.
- `manifest.pdxproj` — registered `tests/test_history.pdx`.

### Changed

- `src/shell.pdx` `shell_main` — after `session_mint` succeeds,
  the entry frame now checks `_sm_opt_no_history`; if unset, it
  calls `history_open_file(1, 1)` (session_id placeholder twice
  today — no `sys_clock_read_ns` wrapper exists in the SC+ floor;
  documented deferral) and stores the raw return in `_sm_hist_fd`.
  On `--no-history` the sentinel `-1` (all-ones) is stored so
  subsequent flush and close calls no-op. The interactive REPL
  loop now calls `history_persist_flush(_sm_hist_fd)` after the
  in-memory ring advance (encoder + `_sm_hist_used += bytes`)
  drains those bytes to disk. Both interactive-mode EOF and `-c`
  exit paths call `history_close_file(_sm_hist_fd)` before
  `sys_exit` for graceful shutdown.
- `caps.decl` — the `KIND_PDXFS_FILE(write)` comment walks back
  the "shell.M2-005" narrative to name ENH-008 as the landing that
  wires the runtime write path, and adds the explicit
  child-cap-non-propagation verification (verified against
  `src/session.pdx::session_derive_subcap`: sub-caps carry
  `SS_RIGHTS_CHILD = 0x3` read+write and never a
  `KIND_PDXFS_FILE` cap of any shape).
- `design/architecture.md` §4b.4 — retitled from "Substrate
  deferral (PdxFS write)" to "Substrate wiring (PdxFS write) —
  landed at ENH-008 (#35)". Walk-back paragraph corrects two
  errors in the original M2 note: the transport is `sys_write` on
  a `KIND_PDXFS_FILE` fd (not `sys_ipc_send` to a broker; no
  `svc.pdxfs-journal` broker exists in the paideia-os tree), and
  the userspace-write path IS wired now. Documents the four new
  functions, the timestamp deferral, and the reboot-persistence
  proof that lives in the paideia-os boot harness.
- `design/architecture.md` §5 — the return-code band table adds
  the four `HI_ERR_*` sentinels under the History module block.
- `STATUS.md` — the "One runtime gap remains" paragraph walks
  back to "**ENH-008 (#35) landed: the shell persists its history
  to disk.**" and the M1 walk-back's ENH-008 bullet flips from
  "still open" to "LANDED at #35". The paideia-os paired landing
  (submodule + `bin_seeds.pdx` wiring) is preserved as a separate
  paideia-os-side gap.

### Deferred

- Timestamp source. No `sys_clock_read_ns` wrapper exists in the
  SC+ floor at ENH-008 landing time; the `ts` argument is passed
  as `session_id` twice with a documented one-line fix at the
  shell_main call site when a clock syscall lands. The wire
  format still carries the ts field verbatim from the encoder's
  input, so the schema is stable.
- Live-kernel partial-write retry test. Verifying the retry loop
  in `history_persist_flush` requires mocking `sys_write` to
  return a short-write count; paideia-as does not carry
  conditional compilation for a function-pointer redirect. The
  retry loop's structural correctness is proved by inspection in
  the flush's justification block; a live-kernel test lands with
  the boot-time smoke harness alongside the reboot-persistence
  proof.
- Reboot-persistence proof. The invariant "run a command, reboot,
  observe the record" requires a live kernel plus persistent-home
  substrate. paideia-os R106.M5 / R107.M1 provide that substrate;
  the boot smoke asserts the invariant, not this repo.

## Unreleased — ENH-007: line reader real bytes (#34)

The `LR_STUB = 0xFFFFEC10` tail of `line_reader_read_line` is retired.
The reader now issues real byte-at-a-time reads from fd 0 via
`sys_read(0, ptr, 1)`, assembling bytes into the caller's buffer
until it sees a newline, EOF, buffer-full, or an unrecoverable read
error. **The shell can read a line.**

The stub's original justification cited "KIND_TTY has not landed
in the paideia-os kernel at HEAD (2026-08-21)"; but 921 lines of
`src/kernel/core/cap/kind_tty.pdx` exist today and only one gap
remains (no `KIND_TTY_OP_READ`, no raw/cooked toggle), which is
already tracked as paideia-os#1986. Rather than block ENH-007 on
that kernel-side improvement, this landing ships against the VFS
fd-0 path — the exact byte-source pattern the paideia-os monorepo's
own `shell_read_line` uses today (`src/user/shell.pdx:29`) — behind
a single seam so the cap-typed migration is a ONE-SITE change when
#1986 lands. See `design/architecture.md` §3.3 for the recorded
deferral rationale.

### Added

- `src/line_reader.pdx` `lr_read_one_byte(byte_ptr) -> u64` — the
  SINGLE SEAM between the LineReader and the byte transport. Sole
  call site of `sys_read` in the module. When paideia-os#1986 lands
  `KIND_TTY_OP_READ`, this one function's body swaps `sys_read`
  for a cap-typed `KIND_TTY(read)` invoke; every other caller (the
  read loop and every future line-editing polish under ENH-011)
  is untouched.
- `src/shell.pdx` `LR_ERR_READ_FAIL = 0xFFFFEC14` — new sentinel
  distinguishing an unrecoverable read error (negative errno from
  `sys_read`) from a clean EOF. `shell_main` treats it as EOF for
  now (exit cleanly rather than spin); a future error-surfacing
  polish can promote this to a user-visible message.
- `tests/test_line_reader.pdx` `TestLineReader` module. Two offline
  input-gate cases in the `0xFFFFED9x` fail band:
  `tlr_case_bad_buf_null` (buf==0 → LR_ERR_BAD_BUF) and
  `tlr_case_bad_buf_len_zero` (buf_len==0 → LR_ERR_BAD_BUF). The
  runtime read-loop matrix (newline-terminated, EOF-at-start,
  buffer-full, mid-stream EOF, read-error) is documented in the
  module header as a deferral to live-kernel invocation: without a
  test-only mock-shim mechanism (paideia-as does not carry
  conditional compilation), the read loop's substrate half exercises
  only under a live kernel with a scripted stdin source, the way
  `test_syscall_floor.pdx` handles `sys_getcwd` / `sys_write`.
  Umbrella `tlr_run_all`.
- `manifest.pdxproj` — registered `tests/test_line_reader.pdx`.

### Changed

- `src/line_reader.pdx` `line_reader_read_line` — body replaced.
  The three-callee-save-push prologue (r12=buf-walker, r13=buf_len,
  r14=count) preserves state across the shell_note + lr_read_one_byte
  nested calls. Loop dispatches by `sys_read` return: 0 == EOF
  (`LR_ERR_EOF` at start; otherwise return count-so-far); signed(rax)
  < 0 == read error (`LR_ERR_READ_FAIL`); else 1 byte was written
  and the loop peeks + advances, jumping back on non-newline. Return
  count INCLUDES the terminating newline (matches the monorepo
  `shell_read_line` shape).
- `src/line_reader.pdx` effect / capability set — widened from
  `!{mem} @{}` to `!{mem, sysreg} @{fs}` covering `sys_read`.
- `src/shell.pdx` `LR_STUB` — REMOVED. The value `0xFFFFEC10` is
  intentionally left unallocated so any external decoder that
  carried the sentinel keeps decoding correctly (the code path is
  simply unreachable in the shell now). Do NOT reuse the value for
  a different meaning without a paired external decoder-refresh
  sweep.
- `src/shell.pdx` `LR_ERR_TTY_UNBOUND` — comment reframed from
  "M2+: KIND_TTY(read) missing" to "reserved: cap-typed
  KIND_TTY(read) missing (paideia-os#1986)". The sentinel remains
  allocated for the cap-typed path that lands when #1986 lands.
- `src/shell.pdx` `shell_main` — EOF-classification branch removes
  the LR_STUB check and adds an LR_ERR_READ_FAIL check. EOF
  sentinel set: `{ 0, LR_ERR_EOF, LR_ERR_READ_FAIL, LR_ERR_BAD_BUF
  (defensive) }`.
- `design/architecture.md` §3 — rewritten to reflect ENH-007. §3.1
  contract enumerates the full return matrix; §3.2 documents the
  ENH-007 implementation loop shape; new §3.3 records the cap-typed
  `KIND_TTY(read)` deferral rationale. §5 return-code band table
  updates the 0xFFFFEC10..0xFFFFEC14 rows.
- `STATUS.md` — walk-back "shell cannot read a line" retired. #34
  moved from open to LANDED.

### Deferred (documented in `design/architecture.md` §3.3)

- Cap-typed `KIND_TTY(read)` invoke inside `lr_read_one_byte`.
  Requires paideia-os#1986 (add `KIND_TTY_OP_READ` op + raw/cooked
  toggle to `src/kernel/core/cap/kind_tty.pdx`). Fallback fd-0
  `sys_read` is behind the same seam so migration is a ONE-SITE
  change; do NOT refile paideia-os#1986.
- Line-editing polish (raw mode, backspace erase, history ring
  recall, cursor movement — R66 shell polish tier 1, issues
  #17-#21, tracked at ENH-011 / #38). Those issues became startable
  only after this landing, since the byte loop they extend did not
  exist until ENH-007.
- Runtime read-loop test matrix (newline-terminated, EOF-at-start,
  buffer-full, mid-stream EOF, read-error). Requires either a
  test-only mock-shim mechanism (not available in paideia-as) or a
  live kernel with a scripted stdin source. Same deferral pattern
  as `test_syscall_floor.pdx`.

## Unreleased — ENH-005: real exec path (#32)

The `EX_STUB = 0xFFFFEC20` tail of `exec_spawn_and_wait` is retired.
The shell now calls `sys_execve` for real, opens a `ShellCommandRecord`
BEFORE the call (D3 audit-first as a running-system property, not just
an encoder property), and closes the record on exit/error. The v1.0.0
walk-back ("shell has never spawned a process") is no longer true.

The M2 CALL GRAPH the module has documented since M1 (`src/exec.pdx`
lines 36-68) is now the LIVE call graph. Two substrate gaps are
retained as documented deferrals (see `src/exec.pdx` §DEFERRALS):
`cap_manifest_verify` (needs libpdx-cap linked) and the real InitCap
sidecar materialiser (needs runtime cap-table introspection). Neither
blocks the ordered sequence; both slot in without touching the body.

The FORK GAP (sys_fork not exposed) is documented as a known
limitation. `sys_execve` under the current syscall floor either
succeeds (never returns; shell becomes child) or fails (returns
errno; audit close with exit=127). The ordered sequence includes
`sys_wait4` for the doc-literal path so a future `sys_fork` insertion
is a one-line addition.

### Added

- `src/exec.pdx` `exec_build_argv_ptrs(pool_ptr, argv_bytes, argc,
  dst_ptrs, dst_max) -> u64` -- marshalling helper that turns the
  Parser's NUL-separated argv pool slice into the child's `char**`
  argv array with NULL terminator at `dst_ptrs[argc]`. Leaf function.
  Refuses `argc + 1 > dst_max` with `EX_ERR_ARGV_OVERFLOW`.
- `src/exec.pdx` `_ex_argv_ptrs[16]` -- built argv array (15 real
  args + 1 NULL terminator per frozen ABI at
  `design/user/execve-abi.md`).
- `src/exec.pdx` `_ex_parent_caps[2]` / `_ex_child_decl[2]` /
  `_ex_sidecar_buf[32]` -- placeholder cap-narrowing fixtures for
  `exec_narrow_child_caps`. Empty child_decl_count=0 makes the
  narrowing trivially succeed; real inputs land when libpdx-cap and
  the runtime cap table wire up.
- `src/exec.pdx` `_ex_audit_rec[32]` (256 bytes) -- ShellCommandRecord
  buffer for the begin/close pair around every spawn.
- `src/exec.pdx` `_ex_wstatus` -- sys_wait4 output slot; low byte
  extracted as exit code on the happy path.
- `src/exec.pdx` `EX_ERR_ARGV_OVERFLOW = 0xFFFFEC27` (build_argv_ptrs
  overflow) and `EX_ERR_AUDIT_BEGIN_FAIL = 0xFFFFEC28`
  (`command_record_begin` returned non-zero; D3 forbids proceeding to
  exec). Extends the existing 0xFFFFEC2x Exec sub-band per the issue's
  "reuse existing band" directive.
- `tests/test_exec.pdx` `TestExec` module. Eight cases in the
  `0xFFFFED8x` fail band: `tex_case_argv_marshal` (verifies pointer
  array construction from `"ls\0-la\0/tmp\0"`), `tex_case_argv_overflow`
  (argc=16 vs dst_max=16 -> overflow), `tex_case_argv_gate_pool`
  (null pool -> BAD_ARGV), `tex_case_argv_gate_dstmax` (dst_max ==
  argc -> overflow), three `tex_case_sw_gate_*` cases for
  `exec_spawn_and_wait`'s own input gates, and the load-bearing
  `tex_case_sw_audit_first` case that drives argv_bytes=9000 > 8192
  to trigger `CMDR_ERR_TOO_LONG` inside `command_record_begin` --
  proving `sys_execve` was NOT reached before the audit gate. Runtime
  spawn fingerprints (`/bin/true` -> 0, `/bin/false` -> 1) are
  deferred to the paideia-os boot smoke post-#33 (shell wired into
  bin_seeds.pdx). Umbrella `tex_run_all`.
- `src/shell.pdx` `EX_ERR_MISSING_CAP` / `EX_ERR_WIDENING` /
  `EX_ERR_SIDECAR_FULL` mirrors (already in exec.pdx from M2-003 but
  not previously exposed at the Shell layer), plus the new
  `EX_ERR_ARGV_OVERFLOW` and `EX_ERR_AUDIT_BEGIN_FAIL` mirrors.

### Changed

- `src/exec.pdx` `exec_spawn_and_wait` -- signature changed from
  `(argv, argv_count)` to `(argv_pool_ptr, argv_bytes, argc)`. The
  new shape takes the parser's per-stage output directly (Parser's
  `_pr_stages[i]` records give `argv_offset` + `argv_bytes` + `argc`;
  the caller passes `_pr_argv_pool + argv_offset`, `argv_bytes`, and
  `argc` verbatim). The M1 signature was fictional -- no caller in
  the shell tree ever consumed it (verified via
  `grep -rn 'exec_spawn_and_wait('` at ENH-005 landing time -- returns
  only design docs and `.plans` notes).
- `src/exec.pdx` body -- the seven-step ordered sequence (build argv
  -> narrow caps -> command_record_begin -> sys_execve -> sys_wait4
  -> command_record_close). The ordering is the load-bearing property;
  a reader reviewing the body top-to-bottom sees each step in the
  same order as the §M2 CALL GRAPH doc.
- `src/exec.pdx` module effect / capability set -- widens from
  `!{mem} @{}` to `!{mem, sysreg} @{sched, mem, fs}` covering the
  union of every downstream call (sys_execve, sys_wait4,
  command_record_*).
- `src/shell.pdx` `EX_STUB` -- retained at value `0xFFFFEC20` with a
  "retired at ENH-005" note so external decoder tables keep parsing;
  the shell body no longer returns it.
- `manifest.pdxproj` -- registered `tests/test_exec.pdx`.

### Deferred (documented in `src/exec.pdx` §DEFERRALS)

- `cap_manifest_verify` (step 3). Requires libpdx-cap linked;
  narrowing at step 2 carries the load-bearing invariant today.
- Real InitCap sidecar materialiser (step 2 inputs). Requires runtime
  cap-table introspection.
- Sidecar handoff at `sys_execve` (step 5). Kernel ABI does not yet
  accept a sidecar arg.
- audit_id + timestamps (steps 4, 7). Placeholders `1` and `0` until
  libpdx-audit + `sys_clock_monotonic` land.
- `sys_fork` wrapper. Absent from #28's Syscall floor by design;
  ENH-005's ordered sequence works today without it and gains
  semantic correctness with a future one-line insertion.

## Unreleased — ENH-004: builtin dispatch (#31)

The v1.0.0 audit and ENH-002/003 landed lex + parse; ENH-004 lands the
in-process command layer. Introduces the `builtin` concept the repo
did not previously carry (no `builtin` symbol in `src/`, `caps.decl`,
or `design/architecture.md` before this change) and the runtime-loaded
triple table (`_bi_names` / `_bi_name_lens` / `_bi_handlers`) that
dispatches argv[0] to one of four handlers.

Design tension resolved: README states shell reads **no environment
variables** and treats env as an ambient-authority channel D5 avoids;
`export` chooses **Option A** per issue (shell-local variable table,
NOT inherited by children). D5 stands; no amendment to
`design/architecture.md` D5; no envp change to sys_execve. The
exported table serves the shell's own subsequent line evaluations
(variable expansion at ENH-006 REPL) -- children see nothing new.

### Added

- `src/builtins.pdx` -- `Builtins` module. Four handlers each with
  signature `(argv_ptr: u64, argc: u64) -> u64`:
  - `bi_cd` -- calls REAL `sys_chdir` (SC+ 85), walker cap 255;
    `argc==1` distinct error `BI_ERR_CD_NO_ARG`.
  - `bi_exit` -- calls REAL `sys_exit` (SC+ 60); parses `argv[1]`
    as decimal (leniency for trailing garbage, matches monorepo
    dec_parse); rejects non-digit first byte with
    `BI_ERR_EXIT_BAD_CODE`; default code 0 when `argc==1`.
  - `bi_export` -- shell-local env table (Option A). Storage:
    `_bi_env` (32 records * 4 qwords: name_ptr, name_len, value_ptr,
    value_len), `_bi_env_pool` (4096 bytes NUL-separated), plus
    `_bi_env_count` / `_bi_env_pool_used` counts. Rejects malformed
    (no '=' or empty name), table full, pool full.
  - `bi_pwd` -- calls REAL `sys_getcwd` (SC+ 86) into `_bi_pwd_buf`
    (256 bytes), then `sys_write(1, buf, strlen) + sys_write(1, '\n', 1)`.
  Fresh return-code sub-band `0xFFFFECEx`: `BI_ERR_CD_NO_ARG`,
  `BI_ERR_CD_FAIL`, `BI_ERR_EXIT_BAD_CODE`, `BI_ERR_EXPORT_MALFORMED`,
  `BI_ERR_EXPORT_TABLE_FULL`, `BI_ERR_EXPORT_POOL_FULL`,
  `BI_ERR_PWD_TOO_LONG`.
- `src/dispatch.pdx` -- `Dispatch` module. Runtime-loaded triple
  table `_bi_names[16]` / `_bi_name_lens[16]` / `_bi_handlers[16]`
  populated at startup by `dispatch_init`. `dispatch_line(argv_ptr,
  argc) -> u64` walks the table with a fast length gate
  (precomputed `_bi_name_lens` avoids per-lookup strlen) and returns
  the handler's result on hit or `BI_MISS = 0xFFFFECE0` on no
  match. Table cap 16 (12 slots headroom above the four initial
  builtins for ENH-005+ additions).
- `tests/test_builtins.pdx` -- `TestBuiltins` module. Six cases in
  the `0xFFFFED7x` band: `dispatch_miss_ls`, `dispatch_hit_export`
  (load-bearing: dispatch -> handler -> record write end-to-end),
  `cd_no_arg`, `export_shell_local` (verifies record layout AND pool
  bytes byte-for-byte), `export_malformed`, `dispatch_hit_pwd`
  (disjunctive: any non-BI_MISS return proves dispatch reached
  bi_pwd; the sys_getcwd round-trip is a live-kernel concern).
  Umbrella `tbi_run_all`. `bi_exit` and `bi_cd`'s live-syscall path
  are intentionally NOT unit-tested (sys_exit would kill the driver;
  sys_chdir needs a live kernel); deferred to the paideia-os boot
  smoke.
- `design/architecture.md` §2d -- Builtins + Dispatch module
  documentation (contract, storage, D5 resolution note, error codes,
  fingerprint) matching the §2b / §2c shape.
- `design/architecture.md` §5 and §7.4 -- return-code table extended
  with the `0xFFFFECEx` Builtins/Dispatch rows and the `0xFFFFED7x`
  TestBuiltins row.
- `README.md` -- new "Built-in commands" section listing cd / exit /
  export / pwd with the D5 note on export scoping.

### Changed

- `src/shell.pdx` -- mirrored `SH_BI_*` constants in the
  `0xFFFFECEx` band alongside the existing `SH_LX_*` / `SH_PR_*`
  mirrors, so a Shell-level caller can spell every builtin/dispatch
  sentinel without explicit Dispatch/Builtins imports.
- `manifest.pdxproj` -- `src/builtins.pdx` + `src/dispatch.pdx`
  registered after `src/parser.pdx` and before `src/line_reader.pdx`
  (logical order: dispatch consumes parser output, feeds the
  ENH-006 REPL); `tests/test_builtins.pdx` appended to the test
  list.
- `STATUS.md` -- return-code table extended with the eight
  `0xFFFFECEx` Builtins/Dispatch rows.

### Unblocks

`#32` real exec (dispatch_line returning `BI_MISS` is the trigger
for the external command path), `#33` `Shell::shell_main` REPL
(the `lex -> parse -> dispatch (builtin) or exec (non-builtin) ->
history -> loop` shape now has dispatch). The critical path from
ENH-001 through ENH-006 is now open at the builtin boundary.

## Unreleased — ENH-003: parser (#30)

The v1.0.0 audit found that `Pipeline::pipeline_plan` took a
pre-counted `stages_count` and `CommandRecord::command_record_begin`
took per-stage null-separated argv text — both were written to be
FED but nobody wrote the feeder. ENH-002 closed the byte-level split
(Lexer); ENH-003 closes the pipeline-level split. Consumes the Lexer
token stream in `_lx_tokens` / `_lx_token_count` and produces a
command list of pipelines-of-stages in fresh `.bss` singletons.
Pure-function; no substrate touch.

### Added

- `src/parser.pdx` — `Parser` module. `parser_parse(input_ptr,
  input_len) → u64` reads the Lexer singletons and populates
  `_pr_stages` (8 stages × 3 qwords: argv_offset, argv_bytes, argc),
  `_pr_stage_count`, and `_pr_argv_pool` (4096-byte contiguous byte
  pool). Words are copied byte-for-byte from the source buffer,
  NUL-separated with a trailing NUL after each word. `PR_MAX_STAGES
  = PL_MAX_STAGES = 8` — a valid parser output is always handable to
  `pipeline_plan` without a second gate. Fresh return-code sub-band
  `0xFFFFECDx`: `PR_ERR_TOO_MANY_STAGES`, `PR_ERR_LEADING_PIPE`,
  `PR_ERR_TRAILING_PIPE`, `PR_ERR_EMPTY_STAGE`,
  `PR_ERR_ARGV_POOL_OVERFLOW`. Non-WORD, non-PIPE tokens (REDIR_*,
  SEMI, AMP) silently skipped at ENH-003; semantics land in
  ENH-004/ENH-005/ENH-006.
- `tests/test_parser.pdx` — `TestParser` module. Eight cases in the
  `0xFFFFED6x` band: `bare_ls`, `pipe`, `pipe_flags`,
  `leading_pipe`, `trailing_pipe`, `empty_stage`, `too_many` (9
  stages), and the LOAD-BEARING `golden_feed` case that wires
  parser output into `pipeline_plan` for `ls | cat` and asserts the
  4 qwords byte-match the existing `tsm_case_pipeline` golden.
  Umbrella `tpr_run_all` matches the family shape.
- `design/architecture.md` §2c — Parser module documentation
  (contract, output shape, downstream contract, error codes,
  fingerprint) matching the §2b Lexer shape.
- `design/architecture.md` §5 and §7.4 — return-code table extended
  with the `0xFFFFECDx` Parser rows and the `0xFFFFED6x` TestParser
  row.

### Changed

- `src/shell.pdx` — mirrored `SH_PR_*` constants in the
  `0xFFFFECDx` band alongside the existing `SH_LX_*` mirrors, so a
  Shell-level caller can spell every parser sentinel without an
  explicit Parser import.
- `manifest.pdxproj` — `src/parser.pdx` registered after
  `src/lexer.pdx` and before `src/line_reader.pdx` (parser consumes
  lexer output, feeds line_reader-driven exec at ENH-006);
  `tests/test_parser.pdx` appended to the test list.
- `STATUS.md` — return-code table extended with the five
  `0xFFFFECDx` Parser rows.

### Unblocks

`#31` builtin dispatch (consumes `_pr_stages[0]`'s first argv word to
choose between builtin and exec paths), `#32` real exec (needs the
per-stage argv slices this parser produces), `#33` `shell_main` REPL
(assembles read → lex → parse → exec). The critical path from
ENH-002 through ENH-006 is now open at the parser boundary.

## Unreleased — ENH-002: lexer (#29)

The v1.0.0 audit found no lexer in the tree; ENH-002 lands one. `Lexer`
turns a caller-owned byte buffer into a token stream in a `.bss`
singleton table. Recognises words, five single-byte operators
(`|<>;&`), single- and double-quoted strings, and backslash escape.
Pure-function; no substrate touch.

### Added

- `src/lexer.pdx` — `Lexer` module. `lexer_tokenize(input_ptr,
  input_len) → u64` populates the `.bss` singletons `_lx_tokens` (128
  × 24-byte records) and `_lx_token_count`. Token vocabulary:
  `TOK_WORD`, `TOK_PIPE`, `TOK_REDIR_IN`, `TOK_REDIR_OUT`, `TOK_SEMI`,
  `TOK_AMP`, `TOK_EOF` (reserved). Fresh return-code sub-band
  `0xFFFFECCx` (LX_ERR_OVERFLOW, LX_ERR_UNTERMINATED_QUOTE,
  LX_ERR_INVALID_ESCAPE, LX_ERR_BAD_ARGS) — the issue's suggested
  `0xFFFFEC5x` collides with the existing Pds allocation.
- `tests/test_lexer.pdx` — `TestLexer` module. Seven golden-fingerprint
  cases (bare `ls`, `ls -l`, `ls | cat`, `ls | cat > /tmp/f`,
  `echo 'a b'`, empty line, whitespace-only line) + umbrella
  `tlx_run_all`, in the `0xFFFFED5x` fail-code band. Matches the
  `tsf_run_all` driver family shape.
- `design/architecture.md` §2b — Lexer module documentation
  (contract, token vocabulary, grouping rules, error codes,
  fingerprint) matching the §2a shape ENH-001 established.
- `design/architecture.md` §5 and §7.4 — return-code table extended
  with the `0xFFFFECCx` Lexer row and the `0xFFFFED5x` TestLexer row.

### Changed

- `src/shell.pdx` — mirrored `SH_LX_*` constants in the
  `0xFFFFECCx` band alongside the existing `LR_*` / `EX_*` mirrors,
  so a Shell-level caller can spell every lexer sentinel without an
  explicit Lexer import.
- `manifest.pdxproj` — `src/lexer.pdx` registered after
  `src/shell.pdx` and before `src/line_reader.pdx` (logical order:
  lexer is a lower-level primitive the line reader will feed at
  ENH-006); `tests/test_lexer.pdx` appended to the test list.

### Unblocks

`#30` parser (consumes the token stream), `#31` builtin dispatch
(dispatches on `TOK_WORD[0]`), `#32` real exec (needs the argv
token stream), `#33` `shell_main` REPL (assembles the read → lex →
parse → exec pipeline). The critical path from ENH-002 through
ENH-006 is now open at the tokenizer boundary.

## Unreleased — ENH-001: syscall floor (#28)

First `syscall` instructions land in the tree. The v1.0.0 audit
(`design/enhancement-plan.md` §1) verified zero `syscall` occurrences
in `src/`; this change lands nine, one per SC+ wrapper the shell v2.0
plan enumerates (Stage 0 in the enhancement plan).

### Added

- `src/syscall.pdx` — `Syscall` module. Nine sysno constants
  (`SYS_READ=0`, `SYS_WRITE=1`, `SYS_OPEN=2`, `SYS_CLOSE=3`,
  `SYS_EXECVE=59`, `SYS_EXIT=60`, `SYS_WAIT4=61`, `SYS_CHDIR=85`,
  `SYS_GETCWD=86`) plus a thin callable wrapper per constant. Each
  wrapper is a leaf function: `mov rax, N; [mov r10, rcx for arity=4];
  syscall; ret`. Effect and capability annotations mirror the
  monorepo's canonical `src/user/syscall_shim.pdx` for each SC+ ID.
- `tests/test_syscall_floor.pdx` — `TestSyscallFloor` module. Runtime
  fingerprint with two cases (`tsf_case_getcwd`, `tsf_case_write`) +
  umbrella `tsf_run_all`, in the `0xFFFFED4x` fail-code band. Same
  driver shape as the four existing test modules; a boot-time smoke
  harness can invoke all five umbrellas in one loop.
- `design/architecture.md` §2a — records the design decision (shared
  module, not per-callsite inline) with the syscall_shim.pdx precedent,
  documents the wrapper surface + calling convention + fingerprint.
- `design/architecture.md` §7.4 — extends the fail-code-band table with
  `0xFFFFED3x` (TestReleaseManifest, prior omission) and `0xFFFFED4x`
  (TestSyscallFloor).

### Changed

- `manifest.pdxproj` — `src/syscall.pdx` registered ahead of
  `src/shell.pdx` in the source list (the shell v2.0 wire will call
  Syscall from Shell::shell_main; source order is documented as
  order-insensitive per the paideia-as module resolver, but the
  logical dependency reads better this way);
  `tests/test_syscall_floor.pdx` appended to the test list.

### Unblocks

Every v2.0 downstream (`#29` lexer, `#30` parser, `#31` builtin
dispatch, `#32` real exec, `#33` shell_main REPL, `#34` line_reader
de-stub, `#35` history de-stub) that had "no syscall substrate" as
its blocker. The critical path from ENH-001 through ENH-006 is now
open at the substrate boundary.

## 0.1.0 — 2026-09-03 — R106.SHELL-001 scaffold consolidation

R106 wave opens. Repo version resets to the R106 wave's 0.1.0 baseline;
R49's v1.0.0 encoder body remains in `src/` and continues to build
under paideia-as v0.29.2. Scaffold consolidation lands the last
pre-landing chores so R106.SHELL-002 (tokenizer) and R106.SHELL-003
(test infra) can move code in without setup friction.

### Added

- `.gitignore` — build-out/, target/, *.o, *.elf, .DS_Store, and
  common editor scratch.
- README.md — R106 mission line, dependency chain (paideia-as +
  libpdx-argv), cross-refs to paideia-os
  `design/roadmap/persistent-home-wave.md` (wave plan) and
  `design/user/content-addressed-identity.md` (novel identity model),
  and cross-refs to R106.SHELL-002 (#41) and R106.SHELL-003 (#42).
- STATUS.md — R106 milestone header + placeholder progress table;
  R49 v1.0.0 material demoted to a historical section.

### Changed

- `manifest.pdxproj` version 1.0.0 → 0.1.0 (R106 wave baseline).

### Cross-refs

- Wave plan: paideia-os `design/roadmap/persistent-home-wave.md` §R106
  + §"Cross-repo scaffolding".
- Paired paideia-os issue: R106.M4-KERNEL.

## 1.0.0 — 2026-08-22

> **Retroactive correction (2026-09-05, shell#37 / ENH-010):** "First
> stable release" below overclaims. `v1.0.0` is a wire-format encoder
> suite — twelve wire encoders and pure bitmask narrowers — not an
> executable shell: zero syscall instructions in `src/`, and its
> declared entry symbol (`Shell::shell_main`) was never written. See
> `design/enhancement-plan.md` §1 for the grep-verified audit and §6
> for why the release that first executes a command is `v2.0`, not
> `v0.2`. The tag and signed release stand as published; only the
> "stable release" / "full shell" characterization below is withdrawn.

**First stable release.** Shell binds itself to the `svc.login-shell`
broker name at session start (M5-001); the login supervisor's path
now has a discoverable endpoint. Dual-signed `manifest.pdxsig` per
`design/manifest-format.md` (pkg §4) is emitted by the release-time
signer via the `ReleaseManifest` encoder introduced this release;
sigblock payloads land once paideia-as reaches the v0.33-crypto-kdf
floor. `.pdxdoc` for `doc shell` ships at `doc/shell.pdxdoc` (M5-002)
and mirrors to `pkgs.paideia-os/main/shell/1.0.0/` per
`design/mirror-push.md`.

### Added (M5)

- `src/release_manifest.pdx` — `ReleaseManifest` module. Wire
  encoder for `manifest.pdxsig` per pkg §4 (header prefix + suffix +
  KV records + sigblock slots). Emits the eleven-tag body layout
  shell v1.0's manifest ships. Sigblock placeholder path zero-fills
  the two ML-DSA-65 signature payloads while pinning the length
  prefixes to 3293 bytes (NIST security level 2) so envelope offsets
  measured by the release lint match the signed release.
- `src/broker_bind.pdx` — `BrokerBind` module. Encoder for the
  `svc.login-shell` broker-bind request the shell sends to the
  paideia-os service broker (R20b.M1-003 at
  `src/kernel/core/ipc/svc_broker.pdx`) at session start.
  `broker_bind_login_shell(dst, dst_len, endpoint_cap, name_ptr,
  name_len, rights_mask)` writes the three-qword header +
  UTF-8 name + zero-padding and returns `BB_STUB` (encoder
  validated; `sys_ipc_send` deferred to M4+ substrate).
- `doc/shell.pdxdoc` — the doc source for `doc shell`, following
  the section conventions in `design/pdxdoc-source.md`. Covers
  synopsis, pipeline model, capability handoff, `.pds` scripts,
  history, differences from POSIX bash/zsh, and the see-also graph.
- `manifest.pdxproj` — paideia-as build manifest bumped to v1.0.0;
  adds `release_manifest.pdx` and `broker_bind.pdx` to the source
  list, `test_release_manifest.pdx` to the test list, and
  `doc/shell.pdxdoc` to the docs list. New `release:` section names
  the signer keys, the ML-DSA security level, the broker name, and
  the mirror target.
- `tests/test_release_manifest.pdx` — 6-case encoder-golden test
  matrix for `ReleaseManifest`: header prefix, header suffix, a
  KV record, a sigblock slot in zero-fill mode, and two hard-reject
  cases (name too long, truncated dst). Golden bytes derived from
  the wire specs and checked in-source via `mov r11, imm64; cmp rax,
  r11`. Umbrella driver `trm_run_all` returns 0 or 0xFFFFED3x.
- `design/release-manifest.md` — shell-specific tag inventory and
  the sigblock placeholder scheme. Sits alongside pkg's
  authoritative wire spec (`design/manifest-format.md`).
- `design/pdxdoc-source.md` — the `.pdxdoc` source-file conventions
  shell adopted for `doc/shell.pdxdoc`; the doc.M1-002 parser is
  the eventual reader.
- `design/mirror-push.md` — the `pkgs.paideia-os` mirror-push
  protocol (file-tree layout, `index.pdxsig` contribution shape,
  hand-off discipline).
- Fail-code bands `0xFFFFECAx` (ReleaseManifest) and `0xFFFFECBx`
  (BrokerBind) added to the 0xFFFFECxx shell error table; test-code
  band `0xFFFFED3x` added for `TestReleaseManifest`.

### Changed

- `manifest.pdxproj` version 0.4.0-m4 → 1.0.0 (see above).

### Deferred to substrate

The release-time ML-DSA-65 sign path and the `sys_ipc_send` wrapper
for the broker-bind wire message stay deferred to a paideia-os round
adjacent to R49 that lands (a) v0.33-crypto-kdf and (b) the broker-
registration IPC schema. Encoder-half testing is in place; the
substrate half slots in without a schema re-negotiation because the
encoder pinned the bytes at M5.

## 0.4.0-m4 — 2026-08-22 (pre-release)

M4 close: tests + smoke matrix (encoder half). See `STATUS.md`.

## 0.3.0-m3 — 2026-08-22 (pre-release)

M3 close: semantic-pipe passthrough + tab-completion + audit
integration.

## 0.2.0-m2 — 2026-08-21 (pre-release)

M2 close: core implementation (session mint, pipeline plan, cap
narrowing at exec, `.pds` executor, history persistence encoder).

## 0.1.0-m1 — 2026-08-21 (pre-release)

M1 close: design + skeleton (Shell / LineReader / Exec modules;
`caps.decl`; return-code band).
