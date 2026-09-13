# shell — CHANGELOG

All notable changes to this project. The format follows Keep a
Changelog conventions; the project follows Semantic Versioning per
`design/tooling/plan.md` §6.

## 0.2.0 — R73 job-control + shell#25 tab completion + shell#32 close

**Job control (partial) — shell#22 / #23 / #24.**

- **`Syscall::sys_kill` (SC+ ID 95).** Thin arity-2 wrapper matching
  `paideia-os src/kernel/core/syscall/handlers/sys_kill.pdx` (landed
  R73.M1-001, paideia-os #1938, closed). Accepts `SIGSTOP=19` and
  `SIGCONT=18` at this landing per the kernel body; any other signum
  returns `-EINVAL`. Effect/cap set `{mem, sysreg} @{sched}`.

- **`Jobs::jb_add_job(pid) -> jid`** and **`Jobs::jb_close_job(pid,
  exit_status) -> u64`.** Row writers over the empty `_jb_jobs_table`
  skeleton R73.M1-006 (#26) shipped; both emit `shell_fp_job_ok`.
  Row layout is unchanged: 3-qword row `{jid:u64, pid:u64, state|
  exit_status:u64}`. Row byte offset `i*24` via `shl 3 + lea [rax +
  rax*2]` to avoid the 2-op `imul r,imm` pitfall documented in
  `feedback_pdx_encoder_pitfalls`.

- **`Jobs::jb_pid_of_jid(jid) -> pid | 0`.** O(1) direct row lookup
  for the bg/fg builtins to resolve their `argv[1]` jid into the
  child pid before `sys_kill` / `sys_wait4`.

- **`Builtins::bi_jobs`.** Walks `_jb_jobs_table[0..JB_TABLE_MAX)`;
  for each active row emits `[job <jid>] <label> pid <pid>\n` in
  one `sys_write` to fd 1. Label is `Running  ` / `Stopped  ` /
  `Waited   ` per the row's state field. Empty table emits
  `no jobs\n`. Registered in `Dispatch` at slot 5.

- **`Builtins::bi_bg`** (shell#23). Parses `argv[1]` as decimal jid
  in `[1, JB_TABLE_MAX]` via `bi_jb_parse_jid`, resolves the pid
  via `jb_pid_of_jid`, calls `sys_kill(pid, SIGCONT=18)`. On
  success rewrites the row's state field to `JB_STATE_BG`. Errors
  in the `0xFFFFECE9..EC` band. Registered at slot 6.

- **`Builtins::bi_fg`** (shell#23). Same jid parse + pid map as
  `bi_bg`, then `sys_kill(pid, SIGCONT)` + `sys_wait4(pid, &wstatus,
  0, 0)` to block until the child exits. Closes the row via
  `jb_close_job` on success. Returns the exit code (low 8 of
  wstatus) rather than `BI_OK` so the REPL sees the real exit.
  Registered at slot 7.

- **`Exec::exec_spawn_and_wait` wired to jobs table.** Parent
  branch now calls `jb_add_job(pid)` after the SHELL FORK OK
  fingerprint (before `sys_wait4`) and `jb_close_job(pid,
  exit_code)` after the exit-code extraction (before `command_
  record_close`). Witness-only wire today: the shell is single-
  threaded and the wait is synchronous, so `jobs` / `bg` / `fg`
  observe the row only in an interleaving that does not exist
  in the current REPL. The scaffolding lands ahead of the
  non-blocking `sys_wait4` path so no rework is needed then.

**Blocked (documented, not landed): shell#22 ^Z in raw mode.**

The `^Z` foreground-stop path needs one of two upstream landings
that do not exist today:

  (a) Kernel `sys_sigaction` + terminal driver delivery of `SIGTSTP`
      to the foreground pgrp on `^Z`. Neither is in
      `paideia-os src/kernel/`.

  (b) A non-blocking `sys_wait4` (options=`WNOHANG=1`) + `sys_poll`
      loop the shell can interrupt from its own line-reader path.
      `sys_wait4`'s WNOHANG arm is undocumented in the kernel body
      today; `sys_poll` has no SC+ wrapper.

`bi_bg` / `bi_fg` / `bi_jobs` and the writers land regardless,
because their run-time is meaningful the moment either upstream
gap closes (no additional shell-side wiring). See
`design/architecture.md` §4.5 for the ledger. (Design doc note
added under `design/architecture.md` at the same landing.)

**Tab completion — shell#25.**

- **`LR_KEY_TAB = 0xFFFFEC58`.** New key sentinel returned by
  `lr_read_key` when it sees `0x09` (HT) in GROUND state. Placed
  after ESC / DEL in the FSM ground dispatch so the existing
  key-recognition tests are unchanged. CSI-state `0x09` is dropped
  by the existing `jb lr_rk_loop` at the parameter-byte gate (per
  ANSI grammar; C0 bytes are never valid CSI parameters).

- **`line_reader_read_line` TAB dispatch.** On `LR_KEY_TAB`, calls
  `Completion::cp_complete_line(buf, count, buf_cap)` and updates
  `r14` (count) + `_sm_line_cursor` from the return value. Matches
  the up/down recall semantics (cursor := end of new content).

- **`Completion::cp_complete_line(buf, count, buf_cap) -> u64`.**
  Full driver:

  1. Scans `buf[0..count)` backwards for the last `' '` to find
     the token prefix. No space -> `argv[0]`; space at index `k`
     -> `argv[1..]` with `prefix_off = k+1`.

  2. Opens `/bin` (argv[0]) or `.` (argv[1..]) via `sys_open(path,
     O_RDONLY=0, 0)`. Failure -> return count unchanged.

  3. Runs the standard `sys_getdents` batch loop with the
     `_cp_dents_buf : [u8; 4096] @align(16)` scratch. Parses the
     12-byte record header (`ino u64 +0`, `name_len u16 +8`,
     `reserved u16 +10`, name at +12; terminator when
     `name_len==0`). u16 name_len read via two `mov_b` + shift +
     `or` because `paideia-as` has no `mov_w` opcode
     (`feedback_pdx_encoder_pitfalls`).

  4. For each entry passing `cp_name_match(name, name_len, prefix,
     prefix_len)`, folds into a running LCP via `cp_lcp_reduce`.
     First match seeds `_cp_lcp_buf`; subsequent matches reduce
     `lcp_len` to the shared prefix length.

  5. `sys_close(fd)`.

  6. If `match_count == 0`: return count. If `match_count > 1`:
     insert `LCP[prefix_len..lcp_len]` (the ambiguity-reducing
     extension). If `match_count == 1`: same, plus a trailing
     space so the next TAB begins `argv[N+1]`. Buffer-overflow
     guard refuses insertion that would exceed `buf_cap`.

  7. Echoes the inserted bytes to fd 1 so the terminal cursor
     tracks the buffer. Returns the new count.

  Bumps `SH_ST_COMPLETIONS` (slot 9) on entry. `cp_name_match`
  and `cp_lcp_reduce` are leaf helpers (no push/pop parity;
  all state in caller-save regs).

**shell#32 closed: EX_STUB retirement documented.**

`Exec::exec_spawn_and_wait` has not returned `EX_STUB` since
ENH-005 (#33 pair) + shell#44 landed the real fork+execve+wait4
path. The stale header comment in `src/exec.pdx` line 285 that
said "still returns EX_STUB on its happy path" is refreshed to
name the sequence that actually runs today (fork -> parent-wait /
child-exec -> audit close -> return exit code). `EX_STUB
(0xFFFFEC20)` is retained in `shell.pdx` as a HISTORICAL band
entry — no live instruction stores it.

**Dispatch table extension.**

`Dispatch::dispatch_init` now populates 8 slots (`_bi_count = 8`)
in the fixed order:

  0. `cd`      (bi_cd)
  1. `exit`    (bi_exit)
  2. `export`  (bi_export)
  3. `pwd`     (bi_pwd)
  4. `help`    (bi_help)      *(landing pending; unresolved externally)*
  5. `jobs`    (bi_jobs)      *(new — shell#24)*
  6. `bg`      (bi_bg)        *(new — shell#23)*
  7. `fg`      (bi_fg)        *(new — shell#23)*

Order stability preserved for slots 0..4 so any existing hard-
coded index reference resolves the same handler.

## Unreleased

- `bi_cd` gains bash-style `cd -` OLDPWD support (shell#14): pre-chdir cwd snapshot into `_bi_oldpwd_buf`, `cd -` swaps + echoes the new cwd, unset-OLDPWD path emits `SHELL CD ERR no oldpwd` fingerprint and returns new sentinel `BI_ERR_CD_NO_OLDPWD` (0xFFFFECE8); `tbi_case_cd_dash_no_oldpwd` locks the reject shape.
## Unreleased — test SCOPE header drift (incidental)

- `tests/test_shell_main.pdx` SCOPE header: "Ten cases" → "Eleven cases" (11 `tshm_case_*` defs; `tshm_run_all` justification + 0xFFFFED8x table already at 11 since #45 landed `tshm_case_repl_pipe_stages`). SH_ST_STAGES (slot 11) constant + `shell_repl_step` loop over `[0, _pr_stage_count)` unchanged; the `bumps by N for an N-stage line` invariant matches the code. Doc-only, no issue reference (survey handle #26 was mismatched — actual issue #26 tracks R73 job-control fingerprints and is not resolved by this edit).
## Unreleased — shell#29-help: `help` builtin auto-enumerates `/bin`

Adds the first user-facing discovery surface for the shell. `help`
emits two sections separated by fixed headers: `--- builtins ---`
listing every currently-registered builtin one-per-line, and
`--- /bin ---` listing every entry the /bin directory exposes to the
current process at the time `help` is invoked.

**New: `Syscall::sys_getdents` (SC+ ID 78).** Thin wrapper matching
the arity-3 (fd, buf, nbytes) → u64 shape of every other sibling
syscall in the module; effect/cap set `{mem, sysreg} @{fs}` mirrors
`sys_read`/`sys_write` with the fs cap for the VFS directory walk.
Kernel body has been landed since paideia-os R56.M3-003 and exercised
in ring-3 by `/bin/ls` since R57.M4-001; the shell was previously not
a consumer.

**New: `Builtins::bi_help` handler.** Signature
`(u64, u64) -> u64 !{mem, sysreg} @{fs}`; argv/argc parameters unused
(help takes no args). Flow:

1. `sys_write` the `--- builtins ---\n` header.
2. Walk `Dispatch::_bi_names` / `_bi_name_lens` (indices
   `0.._bi_count`) and emit each name + `\n`. Live-read of the
   dispatcher's table so future landings that register a builtin in
   `dispatch_init` surface here without a `bi_help` code change.
3. `sys_write` the `--- /bin ---\n` header.
4. `sys_open("/bin", O_RDONLY, 0)`; on fd >= 32 (bad fd OR bit-63-set
   negative errno; same gate shape ls.pdx at
   `postui-os-semsend/src/user/ls.pdx:177` uses) skip the /bin phase
   and return BI_OK.
5. `sys_getdents` loop into `_bh_dents_buf : [u8; 4096]`; walk the
   12-byte-header records (u16 `name_len` at +8 loaded via two
   `mov_b`+shift-add byte reads to avoid the `mov_w` opcode that has
   no other site in this repo, name at +12, terminator when
   `name_len == 0`) and emit each name + `\n`. `.` / `..` are excluded
   by the kernel per project convention (paideia-os
   `design/user/dirent-record.md`), so no filter is needed on the
   ring-3 side.
6. `sys_close(fd)`; return BI_OK.

Section-split (vs a merged flat list) is the operator-facing design
call: users need to know which invocations are shell-internal (no
fork+exec cost, effect+cap set bounded by the handler annotation)
and which are `/bin` binaries (fork+exec, caps narrowed at
`sys_execve`). Merging the two loses that distinction; the cost /
capability posture matters for both interactive use and audit trails.

Error degradation: `sys_open` and `sys_getdents` failures both skip
the /bin phase and return BI_OK. `help` is an operator-comfort
surface, not a semantic gate -- a rootfs that has yet to expose /bin
(early boot, initramfs, chroot rig) should still let the user
discover the in-shell command surface. The dropped /bin section is
diagnosable by its absence in the output rather than a return code
that a REPL would surface as "help failed" (misleading, since the
builtins list did come through).

**New rodata / bss in `Builtins`:**

- `bh_hdr_builtins : [u8; 18] = "--- builtins ---\n\0"` (17 visible +
  1 NUL sentinel per the paideia-as fingerprint-string rule).
- `bh_hdr_bin : [u8; 14] = "--- /bin ---\n\0"` (13 visible + 1 NUL).
- `bh_bin_path : [u8; 5] = "/bin\0"` (4 visible + 1 NUL).
- Length constants `BH_HDR_BUILTINS_LEN = 17`, `BH_HDR_BIN_LEN = 13`.
- `_bh_dents_buf : [u8; 4096] uninit @align(16)` -- sys_getdents work
  buffer sized to `GETDENTS_IO_MAX`.

**Dispatch table extension:**

- New name literal `bi_name_help : [u8; 5] = "help\0"` and length
  constant `BI_NAME_LEN_HELP = 4`.
- `BI_TABLE_N` bumped 4 → 5; `dispatch_init` grows three rows
  (`_bi_names[4]`, `_bi_name_lens[4]`, `_bi_handlers[4]`) and sets
  `_bi_count = 5`. `help` lands at index 4 so pre-existing hard-coded
  index references for cd/exit/export/pwd (0..3) still resolve the
  same handler. `BI_TABLE_MAX = 16` unchanged.

**No new error sentinel:** the 0xFFFFECEx band is unchanged. `help`
never emits a handler-scoped error; any /bin failure degrades to
BI_OK with the builtins section still visible.

Encoder pitfalls check: no `test` mnemonic; every `cmp reg, imm`
uses imm ≤ 0x7FFFFFFF (largest are 32 fd cap, 4096 getdents ret
cap, 12 record header bytes); u16 loads via two `mov_b`+shift-add
byte reads rather than `mov_w` (unused elsewhere in this repo);
byte reads use the `xor rax, rax; mov_b rax, [reg]` #1248 pattern
throughout; no `and reg, imm64` on r8-r15; no 2-op `imul r, imm`;
r11 used only as short-lived .bss LEA and not held across any
call; every label prefixed `bh_` (reserved-label discipline).
## Unreleased — shell#44 retroactive: exec_spawn_and_wait alignment regression test

Retroactive regression test for the fork/exec-path alignment landmine
shell#19 commit 88580b5 removed. That fix pulled a stray `sub rsp, 8`
from `Exec::exec_spawn_and_wait`'s prologue -- entry rsp%16==8, five
callee-save pushes brought rsp%16 back to 0, the stray sub moved it to
8. Every nested SysV CALL (shell_note, sys_fork, sys_execve, sys_wait4,
sys_write, command_record_*, exec_narrow_child_caps,
history_format_u64_dec) ran misaligned; would #GP the first SSE-aligned
callee (`movaps`/`movdqa`) touching `[rsp+K]`. Silent until then --
the shell repo's own callees are all asm-level GP-register-only, so no
existing boot exercised the landmine.

**New file `tests/test_exec_alignment.pdx` (module `TestExecAlignment`):**

- Approach (a) per shell#44 task shape: arithmetic replica-based witness
  (`mov rax, rsp; and rax, 15; cmp rax, 0`). paideia-as 0.36 does not
  yet emit `movaps`/`movdqa` (#1333 shipped scalar-float only; packed
  128-bit deferred), so an SSE-fault probe is not buildable today; the
  arithmetic form witnesses the same property. Module header carries
  the future-enhancement note: replace with `movaps [rsp], xmm0`
  against a 16-byte-reserved stack scratch once the packed-SSE
  mnemonics land.
- `teal_case_replica_current_prologue` — reproduces the POST-88580b5
  prologue (5 pushes, no `sub rsp, 8`); asserts rsp%16==0.
- `teal_case_replica_landmine_prologue` — reproduces the PRE-88580b5
  buggy prologue (5 pushes + `sub rsp, 8`); asserts rsp%16==8 as the
  counter-example. Balanced `add rsp, 8` before the pop sequence keeps
  the epilogue address-correct.
- `teal_case_sut_gate_roundtrip` — round-trips the REAL
  `exec_spawn_and_wait` via its BAD_ARGV gate (argc=0); expects
  `EX_ERR_BAD_ARGV` (0xFFFFEC21). Not a strict alignment probe (gate
  fires before any nested CALL), but a low-cost witness that the
  SUT's real prologue+epilogue push/pop balance survives one
  traversal.
- `teal_run_all` — umbrella; on all-pass emits `EXEC ALIGN OK\n` (14
  bytes) via sys_write(1, ...) so the paideia-os QEMU boot smoke can
  grep-assert positive attestation alongside the existing
  `SHELL FORK OK` / `SHELL RECONCILE` fingerprints.

**Fail-code band 0xFFFFEDFx** — grep audit at landing time
(`grep -oE '0xFFFFED[0-9A-Fa-f][0-9A-Fa-f]' tests/*.pdx src/*.pdx |
sort -u`) confirmed disjoint from every existing 0xFFFFEDxx band
(0..Ex all assigned).

- `TEAL_PASS`          = 0
- `TEAL_FAIL_CURRENT`  = 0xFFFFEDF0  (case 1 saw rsp%16 != 0)
- `TEAL_FAIL_LANDMINE` = 0xFFFFEDF1  (case 2 saw rsp%16 != 8)
- `TEAL_FAIL_SUT_GATE` = 0xFFFFEDF2  (case 3 got != EX_ERR_BAD_ARGV)

**Manifest:** `tests/test_exec_alignment.pdx` added to the `tests:`
list of `manifest.pdxproj`, immediately after `tests/test_exec.pdx`
so the encoder-half exec cases and the alignment-invariant cases
sit adjacent in the build graph.

**tests/README.md:** module entry + band ledger row appended
(`0xFFFFEDFx` -- first failing case in test_exec_alignment).

Encoder pitfalls check: no `test` mnemonic (rsp%16 extraction uses
`and rax, 15; cmp rax, 0`); no `and r, imm64` (mask is imm8 15);
every `cmp reg, imm` uses imm <= 0x7FFFFFFF (0, 8, 15 fit trivially;
0xFFFFEC21 and 0xFFFFEDFx staged via `mov r10, imm32`); r11
(reserved) untouched; no memory reads or byte writes; label
prefixes `teal_rcp_` / `teal_rlp_` / `teal_sgr_` / `teal_ra_` all
avoid the `loop`/`if`/etc. reserved-word set.

Closes #44.

## Unreleased — R73.M1-006 (#26): job-control + tab-completion fingerprints

Lands the observability handle for R73 job-control (bg/fg/jobs/tab-
completion). No caller yet — the row-add / row-complete / match-set
wires land with #22 (sys_setpgid, pgrp mint), #23 (bg/fg + wait4
tracking), #24 (`jobs` builtin), #25 (tab-completion driver). The tag
byte counts are locked at this landing so future callers just call the
emit helpers without a round-trip on the fingerprint spec.

**New file `src/jobs.pdx` (module `Jobs`):**

- `_jb_jobs_table : [u64; 48] = uninit @align(64)` — 16 rows × 24 bytes
  each. Row layout: `{jid: u64, pid: u64, state: u32, exit_status: u32}`.
  Empty today; #22/#23 install the writers.
- `JB_TABLE_MAX = 16`, `JB_ROW_SIZE = 24`, plus row-field byte offsets
  (`JB_ROW_OFF_JID / _PID / _STATE / _EXIT_STATUS`) and state
  vocabulary placeholders (`JB_STATE_FREE / _BG / _STOPPED / _WAITED`).
- Rodata `jb_fp_job_ok_prefix` (18 bytes visible: `shell job ok -- n=`),
  `jb_fp_job_ok_sep_pid` (5 bytes: ` pid=`), `jb_fp_job_ok_sep_state`
  (7 bytes: ` state=`). Each `[u8; N]` = strlen + 1 per the paideia-as
  fingerprint-string rule.
- `shell_fp_job_ok(n, pid, state) -> ()` — single-write fingerprint
  witness emitting `shell job ok -- n=<N> pid=<P> state=<S>\n` to fd 2.
  Prologue: 4 callee-save pushes + `sub rsp, 104` = 136 bytes; 104-byte
  stack scratch covers the 91-byte worst-case composition.

**Extended `src/completion.pdx` (module `Completion`):**

- Rodata `cp_fp_complete_ok_prefix` (28 bytes visible:
  `shell complete ok -- prefix=`), `cp_fp_complete_ok_sep_matches`
  (9 bytes: ` matches=`), `cp_fp_complete_ok_nl` (1 byte: `\n`).
- `shell_fp_complete_ok(prefix_ptr, prefix_len, matches) -> ()` —
  five-sys_write fingerprint witness emitting
  `shell complete ok -- prefix=<X> matches=<M>\n` to fd 2. Multi-write
  keeps arbitrary-length `<X>` off the stack (COMP_NAME_MAX == 512).
  Prologue: 3 callee-save pushes + `sub rsp, 32` = 56 bytes.

**Extended `src/shell.pdx` (module `Shell`):**

- Two new stats slot constants: `SH_ST_JOBS = 14`, `SH_ST_JOBS_COMPLETED
  = 15`. Both live inside the existing 16-slot `_shell_stats` table (no
  layout change; slots 13..15 were already reserved). Bumped by the
  future #22/#23 sites around `shell_fp_job_ok`, not inside the witness,
  so a state-transition-only call and a fresh row-add call can bump
  different counters.

**Manifest:** `src/jobs.pdx` added to the `sources:` list of
`manifest.pdxproj` between `src/command_record.pdx` and
`src/release_manifest.pdx`.

Encoder pitfalls check: no `test` mnemonic, no `and r, imm64`, no
2-operand `imul r, imm`; every `cmp reg, imm` uses imm ≤ 0x7FFFFFFF
(byte-count literals 18, 5, 7, 27, 9 fit trivially); every byte
memory access uses the `xor + mov_b + [ptr + idx * 1]` pattern.

## Unreleased — R66.M1-004 (#20): cursor-left/right in-place edit

Fills in the LEFT/RIGHT arrow branches R66.M1-001 (#17) landed as
recognised-but-ignored no-ops in `line_reader_read_line`. The shell
now tracks an in-line cursor within the not-yet-submitted line and
honours mid-line insert and mid-line backspace with a single-write
tail redraw per `design/user/shell-line-editing.md` §7.

Two new `.bss` singletons live in `module Shell`:

- `_sm_line_cursor : u64` — insertion-point offset within
  `_sm_line_buf`, in `[0, count]`. Reset to 0 at every
  `line_reader_read_line` entry (line-scoped state per §7.1).
- `_sm_line_edit_scratch : [u8; 8192]` — compose buffer for the
  mid-line redraw `sys_write` bundle. Sized to cover the worst-case
  `3 + 2*4094 = 8191` (BS worst case with 4094-byte tail; buf_len=4096 caps
  cursor at 4095, so max tail = 4094) — buffer sized at 8192.

Behaviour by key:

- LEFT (`SK_LEFT`): if `cursor > 0`, `cursor--`, `sys_write(1, "\b", 1)`.
- RIGHT (`SK_RIGHT`): if `cursor < count`, `sys_write(1, "ESC [ C", 3)`,
  `cursor++`. `ESC [ C` is a pure motion — no dependence on the
  glyph at the old cursor position.
- LITERAL byte at `cursor < count`: `lr_insert_mid` shifts the tail
  right, stores the byte, then emits `byte + tail + \b × tail_len`
  in one `sys_write` (§7.4). Recall cursor is reset to head per
  §6.3 draft-promotion.
- LITERAL byte at `cursor == count`: existing end-append fast path,
  `cursor` advances alongside `count`.
- BACKSPACE at `cursor == 0`: full no-op (column-zero, §5.1).
- BACKSPACE at `cursor == count`: existing `\b \b` end-erase, plus
  `cursor--`.
- BACKSPACE at `0 < cursor < count`: `lr_bs_mid` shifts the tail
  left, then emits `\b + tail + space + \b × (tail_len + 1)` in
  one `sys_write` (§7.5). Does NOT reset the recall cursor.
- ENTER (`0x0A`): commit the whole buffer regardless of cursor
  position — `mov_b [r12 + r14 * 1], 0x0A; r14++; return`.
- UP / DOWN arrow (recall): after `lr_recall_up` / `lr_recall_down`
  returns a new count, `_sm_line_cursor := new_count` so the next
  typed byte appends normally (§6.3 step 3).

`r12` remains the buffer BASE (immutable) per the R66.M1-003 (#19)
refactor; nothing in the cursor path walks `r12`.

### Added

- `src/shell.pdx`:
  - `_sm_line_cursor : u64 = uninit @align(8)` — in-line cursor slot.
  - `_sm_line_edit_scratch : [u8; 8192] = uninit @align(16)` —
    redraw compose buffer.
  - `shell_reset` zeros `_sm_line_cursor` alongside the R66.M1-003
    history-ring cursors, so test-fixture reset stays honest.
- `src/line_reader.pdx`:
  - `lr_bs_one_str : [u8; 2] = "\x08\0"` — one 0x08 byte for LEFT.
  - `lr_move_right_str : [u8; 4] = "\x1b[C\0"` — `ESC [ C` for RIGHT.
  - `lr_insert_mid : (u64, u64, u64, u64) -> u64` — shift-right +
    store + tail-redraw + cursor update. Returns `count + 1`.
    5 callee-save pushes (`rbx r12 r13 r14 r15`), no `sub rsp`, so
    `rsp%16==0` at the nested `sys_write` (per the user's #20
    alignment warning against `sub rsp, 8` under 5 pushes).
  - `lr_bs_mid : (u64, u64, u64) -> u64` — shift-left + tail-redraw
    + cursor update. Returns `count - 1`. Same 5-push alignment
    shape (r12 push is a padding slot).
  - `line_reader_read_line` dispatch: LEFT / RIGHT / mid-insert /
    mid-BS branches; ENTER-first check on the raw-byte path; cursor
    reset at prologue; cursor update after UP / DOWN recall.

### Changed

- `line_reader_read_line`'s justification block widens to cover the
  #20 cursor branches and the ENTER-first ordering on the raw-byte
  path.

### Design cross-references

- `design/user/shell-line-editing.md` §7 (cursor spec) and §11
  (state allocation) — the authoritative behaviour reference.
- Encoder pitfalls: stack alignment under 5 pushes (never
  `sub rsp, 8`), `mov_b` with `* 1` scale (U1606), and byte load
  via `xor + mov_b` (#1248) — all observed.

Fingerprint: none dedicated for #20 per the issue's fingerprint
row; covered by the R66.M1-005 (#21) design doc's worked examples.

Closes paideia-os/shell#20.

## Unreleased — R66.M1-003 (#19): history ring buffer + up/down recall

Fills in the arrow-key recall branches R66.M1-001 (#17) landed as
recognised-but-ignored no-ops in `line_reader_read_line`. The shell
now walks a flat-text history ring on up/down arrow, replaces the
current visible line with the recalled entry, and reprints via a
`\r ESC[K` clear-line + prompt + recalled-bytes sequence to fd 1.

The 8 KiB `Shell::_sm_hist_buf` retains its previous storage
allocation but its semantics move from wire-encoded records to flat
text (per `design/user/shell-line-editing.md` §6.1): each committed
entry contributes `<cmd-bytes><0x0A>` and the ring holds two views
in one place. The old ENH-006 (#33) write path
(`history_encode_record` into the ring + `history_persist_flush`
draining the ring) is retired at the call site in `shell_main`; the
new `sm_hist_ring_commit` helper owns both the flat-text append AND
the wire-encoded `sys_write` to `_sm_hist_fd` in one action, so the
in-memory recall view and the on-disk journal cannot drift.

Three new `.bss` cursors track ring state -- `_sm_hist_head`
(write cursor), `_sm_hist_tail` (oldest entry), and
`_sm_hist_recall_cursor` (currently-recalled entry). The ring reserves
one slot so `(head + 1) mod cap == tail` signals full; on overrun
`tail` walks forward past the next `0x0A` so every surviving entry is
whole. Typing any raw byte during recall resets the recall cursor to
head per the design's "commit on literal" semantic; backspace does
not (matching the design's "edit continues on the recalled draft"
rule). The `line_reader_read_line` register plan flips so `r12` is
the buffer BASE (immutable) and byte writes use
`mov_b [r12 + r14 * 1], rax`, letting the recall helpers set `r14 :=
new_count` without also rewinding a walking cursor.

The `shell history ok -- entries=<N>` fingerprint is emitted to fd 2
after every commit by a new `history_ring_witness` helper -- `<N>`
is walked live (not cached) from `_sm_hist_tail` to `_sm_hist_head`
counting `0x0A`.

### Added

- `src/shell.pdx`:
  - `pub let SH_ST_RECALL : u64 = 12` -- per-arrow-key-press counter
    slot; bumped by `lr_recall_up` / `lr_recall_down` on every walk.
  - `_sm_hist_head`, `_sm_hist_tail`, `_sm_hist_recall_cursor` (three
    `u64 @align(8)` .bss slots) and `_sm_hist_enc_scratch : [u8; 4128]
    @align(16)` (wire-encode staging for the persistence write-through).
  - `sm_fp_hist_ok_prefix` rodata (28 visible bytes + NUL) +
    `sm_fp_hist_ok_prefix_len` u64.
  - `sm_hist_ring_commit(cmd_ptr, cmd_len) -> u64` -- flat-text ring
    append + wire-encoded `sys_write` to `_sm_hist_fd` in one atomic
    action. Empty-line short-circuit; pre-write tail-advance guard;
    recall cursor reset; fingerprint emission.
  - `history_ring_witness() -> ()` -- walks the ring counting
    `0x0A` separators and emits the fingerprint to fd 2.
- `src/line_reader.pdx`:
  - `pub let LR_KEY_RECALL_NOP : u64 = 0xFFFFEC57` -- returned by
    the recall helpers when the walk hit a boundary and no state
    changed; the read-loop compares against it and iterates.
  - `lr_redraw_clear` rodata (`\r ESC[K` + NUL) +
    `lr_redraw_clear_len` u64.
  - `lr_recall_redraw(buf, len) -> ()` -- three-`sys_write`
    line redraw (clear + prompt + buf) shared by both recall helpers.
  - `lr_recall_up(buf, buf_cap) -> u64` -- back-scan for the previous
    `0x0A` boundary; copies the recalled entry into the caller's buf;
    redraws; updates recall cursor.
  - `lr_recall_down(buf, buf_cap) -> u64` -- symmetric forward scan;
    empty-draft transition returns `len == 0`.

### Changed

- `src/shell.pdx`:
  - `_sm_hist_buf` semantics documented as flat text (was wire-encoded
    records); the allocation itself is unchanged.
  - `_sm_hist_used` documented as deprecated -- retained as a linkage
    stub so `history_persist_flush` (which reads it) keeps compiling;
    `shell_reset` now zeroes it explicitly and no other write path
    populates it.
  - `shell_reset` widens to also zero the three R66.M1-003 cursors.
  - `shell_main` REPL-loop history-append block is replaced by a
    single `sm_hist_ring_commit(_sm_line_buf, cmd_len)` call
    (trailing newline stripped inline before the call); the
    `history_encode_record` / `history_persist_flush` pair is retired
    from this call site.
- `src/line_reader.pdx`:
  - `line_reader_read_line` register plan: `r12` is now the buffer
    BASE (immutable); byte writes use `mov_b [r12 + r14 * 1], rax`;
    backspace only decrements `r14`.
  - Raw-byte append path now unconditionally resets
    `_sm_hist_recall_cursor := _sm_hist_head` (idempotent when not
    recalling) per §6.3 "commit on SK_LITERAL".
  - `LR_KEY_UP` / `LR_KEY_DOWN` branches call `lr_recall_up` /
    `lr_recall_down` and update `r14` from the returned count.

## Unreleased — R106.SHELL-003 (#42): tokenizer test infrastructure

Lands `tests/test_tokenizer.pdx` -- `TestTokenizer` module with a
fourteen-case matrix over the R106.M1 `Tokenizer.tokenize` surface
at `src/tokenizer.pdx`. Covers every documented behaviour: empty
input, whitespace-only, bare single word, two whitespace-separated
words, single-quoted fragment, double-quoted fragment, double-quote
body backslash-escape, bare backslash-escape outside quotes,
adjacent-fragment glue (`hello'a b'world` = ONE token), unterminated
single-quote error, unterminated double-quote error, invalid-escape
error (bare backslash at EOL), overflow error (cap=1 with two
words), and bad-args error (null line_ptr with non-zero length).
Fail-code band 0xFFFFEDBx claimed; `ttk_run_all()` matches the
`tsf_run_all` / `tlx_run_all` umbrella shape so the paideia-os
boot-time smoke can invoke it in one loop with the other drivers.

The three #41-dependent test files the issue body names
(`tokenizer_tilde.pdx`, `tokenizer_bare_cd.pdx`,
`dispatch_argv_construction.pdx`) reference symbols the
R106.SHELL-002 (#41) landing has not added yet -- the novel-tilde
expansion inside the tokenizer, the ambiguous-target error in
bare `cd`, and the dispatch-argv plumbing for a mid-argv `~alice`.
Those tests land alongside #41 in the commit that first ships their
SUT symbols; band 0xFFFFEDCx reserved. The shared `tests/harness.pdx`
witness-primitive surface (`test_ok` / `test_fail`) lands with them
so its first callers exist in the same commit.

### Added

- `tests/test_tokenizer.pdx` -- `TestTokenizer` module, fourteen
  cases + `ttk_reset` fixture populator + `ttk_run_all` umbrella.
- `manifest.pdxproj` `tests:` list gains the new test target so
  `bash tools/build.sh` picks it up automatically.
- `tests/README.md` ledger row for the new module + its band.
- `STATUS.md` R106.SHELL-003 marked LANDED.

## Unreleased — ENH-009 (#36): drop `libpdx-elevate` (link-or-drop → drop)

Removes the `libpdx-elevate @ ^0.2` manifest dependency, its
mirrored `SH_KIND_ELEVATE_CHANNEL` constant, and the associated
docs prose. The dep was declared as "reserved for a future
`.pds requires: elevate` consumer" but no such consumer existed
in the tree: `caps.decl`'s `requires:` block does not name
`KIND_ELEVATE_CHANNEL`, no `elevate_client_*` symbol is called
anywhere in `src/` or `tests/`, and `Pds`'s parsed `requires:`
list has no reader. Carrying a declared dependency the binary
never links is a supply-chain claim `pkg` and the release
manifest would surface to users; the drop honours the artifact
instead. When a real privileged `.pds` path is scoped end-to-end
(broker call site, refusal exit 4 per the exit-code table, and
the caps.decl request), re-add the dep, the ordinal mirror, and
the caps.decl line in a single paired PR. See
`design/enhancement-plan.md` §5.

### Removed

- `manifest.pdxproj` `- libpdx-elevate @ ^0.2` deps line. The
  paragraph above the `deps:` block now records the drop and the
  re-add contract instead of the "reserved" rationale.
- `src/shell.pdx` `pub let SH_KIND_ELEVATE_CHANNEL : u64 = 0x191`
  and the `SH_KIND_ELEVATE_CHANNEL` line in the KIND-mirror
  comment. An in-place note in the same comment block explains
  the drop and the re-add contract so a future reader sees why
  0x191 is absent.

### Changed

- `src/shell.pdx` SCOPE prose — the "same reason libpdx-elevate
  mirrors ELV_*" attribution is replaced with the libpdx-cap
  RIGHTS_* precedent (the actual mirror discipline the shell
  follows). The disjoint-error-band paragraph keeps
  libpdx-elevate's `0xFFFFEAxx` window named as a placement
  anchor -- so re-adding elevate later cannot collide -- but
  frames it as historical.
- `README.md` "Dependency chain" section -- the additional-deps
  paragraph no longer lists `libpdx-elevate`, and a new
  paragraph states elevate integration is out of scope until a
  privileged `.pds` consumer is scoped end-to-end.
- `design/architecture.md` §2.1 (KIND ordinal mirrors bullet)
  and §5 (band-placement paragraph) refreshed in step with the
  source drop; the mirror bullet drops
  `SH_KIND_ELEVATE_CHANNEL = 0x191` from the enumerated list and
  records the ENH-009 drop.
- `design/enhancement-plan.md` §5 rewritten from "forces the
  choice" to "resolution — dropped", with the historical
  problem statement preserved for provenance; the roadmap table
  row for ENH-009 marks the issue as landed.
- `tests/test_caps_narrow.pdx` matrix-scope comment -- the
  stale `TCN_KIND_ELEVATE = 0x191` mirror line is removed and
  the "matrix does not touch KIND_ELEVATE_CHANNEL" paragraph now
  cites the ENH-009 drop as the reason no in-tree ordinal
  exists for the matrix to reference.

### Unblocks

- The release-manifest `deps:` block now reflects the symbols
  the binary actually resolves. `pkg` output no longer
  overstates the shell's runtime surface.
## Unreleased — #39: exec-time reconciliation framing in sys_execve path (R90-XREPO.013.M2-001)

Adds a NEW step (6a) to `exec_spawn_and_wait`'s parent branch,
between successful `sys_wait4` and `command_record_close`:
`exec_reconcile_publish(count)` publishes the child's reconciled
cap-set count to a shell-per-job scratch (`_ex_reconciled_caps_count`)
and emits the boot-visible fingerprint
`SHELL RECONCILE n=<c>\n` via three `sys_write(1, ...)` calls
(prefix + decimal count + newline). This wires the audit
surface and the ordering that R90-XREPO.013.M2-001 requires:
"invoke exec-time cap reconciliation for every child before
returning control, publish the reconciled caps in the shell's
per-job record."

DEFERRED (documented in `src/exec.pdx` §DEFERRALS): the real
user-space `sys_exec_reconcile_caps` syscall wrapper. The
kernel-side substrate landed at paideia-os R90-XREPO.013.M0-001
(`src/kernel/core/cap/reconcile.pdx` `cap_reconcile_at_exec`)
as a kernel-internal function; its SC+ ID for the user-space
wrapper is not yet allocated. When it lands, only the body of
`exec_reconcile_publish` gains a `call sys_exec_reconcile_caps`
between the publish and the fingerprint -- the call site in
`exec_spawn_and_wait`, the publish slot, and the fingerprint
shape all stay identical. The count published today equals the
`child_decl_count` from step (2) (0 under the ENH-005
placeholder inputs); when the parent-cap materialiser + real
`caps.decl` parser land, the count reflects the kernel-narrowed
cap-set the child actually received.

Refs paideia-os/shell#39; sub-issue of paideia-os/paideia-os#2002
(R90-XREPO.013 exec-time cap reconciliation adoption campaign).

### Added

- `src/exec.pdx` `EX_ERR_RECONCILE_FAIL : u64 = 0xFFFFEC2A` --
  new 0xFFFFEC2x sub-band sentinel reserved for a non-zero
  return from `exec_reconcile_publish`. Unreachable today (the
  stub cannot fail); named for the future real-syscall landing
  so callers may compile their reject branch against a stable
  name without waiting on the substrate flip. Same close-then-
  return discipline as `EX_ERR_WAIT_FAIL`: the audit record was
  OPENed at step (4) and must be CLOSEd (exit=127) before
  returning the sentinel to avoid an orphan OPEN in the audit
  journal.

- `src/exec.pdx` `_ex_reconciled_caps_count : u64` -- per-job
  publish slot for the shell's reconciled cap-set count. Exposed
  as `pub let mut` so downstream consumers (a future
  `audit_commit` variant, R90-XREPO.013.M4-* boot smoke asserts)
  can read it without wiring another cross-repo channel.

- `src/exec.pdx` `_ex_fp_reconcile_scratch : [u8; 24]`,
  `ex_fp_reconcile_str : [u8; 19] = "SHELL RECONCILE n=\0"`,
  `EX_FP_RECONCILE_LEN : u64 = 18` -- fingerprint literals for
  the parent-visible `SHELL RECONCILE n=<c>\n` emission. Scratch
  sized identically to `_ex_fp_pid_scratch` (24 bytes = 20
  digit-max + 4-byte 16-B align pad); the paideia-as fingerprint-
  string N-rule (N = strlen + 1 for the trailing NUL) gives
  N=19 for the 18-byte prefix.

- `src/exec.pdx` `exec_reconcile_publish : (u64) -> u64 !{mem,
  sysreg} @{fs}` -- publishes count to `_ex_reconciled_caps_count`
  and emits the three-part fingerprint. 2-push (rbx, r12) +
  `sub rsp, 8` = 24 bytes prologue; rsp % 16 == 0 at every
  nested SysV call. r12 carries `count` across `sys_write` +
  `history_format_u64_dec` so the .bss store and the fingerprint
  read the same value. Labels prefixed `ex_rp_`. Returns 0
  unconditionally today (reserved for a genuine kernel-OOM
  return path when the real `sys_exec_reconcile_caps` lands).

### Changed

- `src/exec.pdx` `exec_spawn_and_wait` parent branch --
  insert step (6a) between wait4 success and command_record_close:
  `xor rdi, rdi; call exec_reconcile_publish; cmp rax, 0; jne
  ex_sw_reconcile_fail`. r15 (child exit code) survives the
  publish call per SysV callee-save (both `sys_write` and
  `history_format_u64_dec` preserve r15).

- `src/exec.pdx` `exec_spawn_and_wait` -- add
  `ex_sw_reconcile_fail` reject arm: close audit with exit=127,
  bump `SH_ST_ERRORS`, return `EX_ERR_RECONCILE_FAIL`. Matches
  the `ex_sw_wait_fail` discipline for orphan-OPEN avoidance.

- `src/exec.pdx` §M2 CALL GRAPH doc block -- add step (6a);
  §DEFERRALS -- add "real `sys_exec_reconcile_caps` syscall
  wiring"; sentinel enumeration -- extend 0xFFFFEC2x range to
  0xFFFFEC2A.

### Unblocks

- R90-XREPO.013.M3-* (per-tool caps.decl adoption for ls / cat /
  cp / mv / rm / mkdir / doc): the parent-visible fingerprint
  is now emitted for every child, so a per-tool test can grep
  for `SHELL RECONCILE n=<expected>` on the QEMU boot log once
  the shell is wired into `bin_seeds.pdx`.

### Notes

- No new `test` mnemonics; every zero-check uses `cmp reg, 0`
  per paideia-as reserved discipline.
- `and rax, 0xFF` (existing) fits imm32 <= 0x7FFFFFFF; no new
  large-immediate `and` forms introduced (the pitfall
  `and r11, imm64` is not exercised).
- Fingerprint string N-rule verified: `"SHELL RECONCILE n="`
  strlen = 18, N = 19.
- `_ex_fp_reconcile_scratch` kept separate from
  `_ex_fp_pid_scratch` even though the two runs never overlap
  in time -- future concurrent-child work will require distinct
  per-fingerprint scratches, and separating them now is free
  (24 bytes .bss).

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
## Unreleased — shell#44: sys_fork syscall floor bump + live spawn fingerprint

Retires the ENH-005 §FORK GAP. `exec_spawn_and_wait` now forks before
exec: the child branch calls `sys_execve` (and `sys_exit(127)` on
failure), while the parent branch emits a boot-log fingerprint and
waits on the specific child pid. `sys_wait4` is genuinely reachable
on the parent timeline for the first time; `command_record_close`
runs on the parent side after wait so the audit journal always sees
matched OPEN/CLOSE pairs.

The `SHELL FORK OK pid=<n>\n` fingerprint is asserted by the paideia-
os QEMU boot smoke once the shell is wired into `bin_seeds.pdx`
(paideia-os-side, sequenced after shell#33 landed); the shell repo's
local build proves the write sequence compiles.

Unblocks the paideia-os `bin_seeds.pdx` seeding that
`design/roadmap/rows-4-5-6-scoping.md` §4.2 has been waiting on
since ENH-005 landed.

### Added

- `src/syscall.pdx` `Syscall::sys_fork` — SC+ 56 wrapper. Arity 0,
  no arg shuffle; effects `{mem, sysreg}`, capabilities `{sched,
  mem}`. Matches paideia-os `src/user/syscall_shim.pdx` `sys_fork`
  byte-for-byte in its syscall body. The floor grows from 9 to 10
  wrappers.
- `src/syscall.pdx` `SYS_FORK : u64 = 56` — sysno constant.
- `src/exec.pdx` `EX_ERR_FORK_FAIL` (0xFFFFEC29) — new sentinel for
  the parent-side "sys_fork returned negative errno (kernel OOM,
  typically -EAGAIN or -ENOMEM)" case. Distinct from
  `EX_ERR_EXECVE_FAIL` because a fork failure is a kernel resource
  exhaustion signal, whereas an execve failure now surfaces as the
  child's exit code 127.
- `src/exec.pdx` fingerprint rodata: `ex_fp_fork_ok_str`
  ("SHELL FORK OK pid=" + NUL, 19 bytes; `EX_FP_FORK_OK_LEN = 18`
  is the sys_write count) and `ex_fp_nl_str` ("\n" + NUL, 2 bytes).
- `src/exec.pdx` `_ex_fp_pid_scratch : [u8; 24]` — .bss scratch
  for the decimal pid render (20 digits max + 4 bytes slack /
  8-byte alignment).
- `src/shell.pdx` `EX_ERR_FORK_FAIL` mirror (0xFFFFEC29) alongside
  the other `EX_ERR_*` sentinels.

### Changed

- `src/exec.pdx` `exec_spawn_and_wait` body: inserts `call sys_fork`
  between `command_record_begin` and `sys_execve`. Three arms —
  `jl` (signed) → parent fork-fail close + return
  `EX_ERR_FORK_FAIL`; `je` → child sys_execve then `sys_exit(127)`
  on failure; else (parent) → stash child pid in `rbx`, emit
  fingerprint via three `sys_write(1)` calls (prefix, decimal pid
  via `history_format_u64_dec`, newline), then `sys_wait4(pid=
  child_pid, ...)` on the specific pid rather than the previous
  `pid=-1`.
- `src/exec.pdx` `EX_ERR_EXECVE_FAIL` is now unreachable from the
  parent-visible return path (constant retained in `shell.pdx` for
  the old-decoder compat window). The child branch replaces the
  sentinel with `sys_exit(127)` so the parent's `wait4` surfaces
  the failure as a POSIX-shaped exit code.
- `src/exec.pdx` M2 CALL GRAPH doc: adds step (4a) sys_fork with
  three-arm return convention; annotates (5) as CHILD-BRANCH ONLY
  and (6)/(7) as PARENT-BRANCH ONLY.
- `src/exec.pdx` §FORK GAP block: replaced by §"FORK: LIVE
  (shell#44 retirement of the ENH-005 §FORK GAP)". Historical note
  preserved.
- `src/exec.pdx` register plan: `rbx` repurposed as the child-pid
  carrier on the parent branch after fork (previously nominally
  reserved as a scratch that was never actually used in the ENH-005
  body).
- `src/syscall.pdx` module docstring: bumps the "nine SC+ IDs" line
  to "ten" and adds the SC+ 56 row.

### Notes

- No manifest / version bump: the CHANGELOG track stays `Unreleased`
  through shell#44 alongside the existing ENH-008 entry.
- Kernel-side ground truth: `sys_fork_body` at paideia-os
  `src/kernel/core/syscall/handlers/sys_fork.pdx` (landed
  R15-M6-003 #554; child-materialisation completion R17-M0-724-D6
  #724). No paideia-os-side change is required to land shell#44;
  the wrapper joins existing kernel infrastructure.
- End-to-end runtime proof (`SHELL FORK OK pid=<n>` in the QEMU
  boot log) requires paideia-os `bin_seeds.pdx` to seed the shell
  ELF and land the boot smoke that asserts the string; that pair
  is paideia-os-side and sequenced after shell#33.

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
