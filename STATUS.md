# shell — status

> **v1.0.0 was a wire-format encoder suite; `shell` could not execute a
> command.** ENH-001 (#28) landed the syscall floor, ENH-005 (#32)
> landed the real exec path, **shell#44 landed the fork-before-exec
> pattern that retires the ENH-005 §FORK GAP**, and **ENH-006 (#33)
> lands `Shell::shell_main` + REPL and flips `manifest.pdxproj` `kind`
> back to `tool`**. The commit that lands #33 is the first at which `shell`
> is a shell: `src/shell.pdx` now defines `shell_main` (the ELF entry
> the manifest has declared since M1), a CLI flag walker
> (`shell_argv_dispatch`) that recognises `-c` / `--no-history` /
> `--no-cap:<KIND>` / positional `<script.pds>`, and
> `shell_repl_step` that runs one line through lex -> parse ->
> dispatch -> exec.
>
> **ENH-007 (#34) landed: the shell can read a line.** The M1 stub
> tail (`line_reader_read_line` returning `LR_STUB = 0xFFFFEC10`)
> is retired; the reader now calls `sys_read(0, ptr, 1)` byte-at-a-
> time behind a single seam (`lr_read_one_byte`), assembling bytes
> into the caller's buffer until it sees a newline, EOF, buffer-full,
> or an unrecoverable read error. The cap-typed `KIND_TTY(read)`
> invoke stays deferred behind the same seam. paideia-os#1986 landed
> `TTY_OP_READ` (ordinal 6, R_TTY_READ 0x080, CLOSED 2026-08-31);
> the seam swap still needs two upstream landings (KIND_TTY absent
> from `KIND_SEEDABLE_TABLE`; no shell-time TTY cap seed at boot)
> plus a `sys_yield` addition to the shell's Syscall floor for the
> non-blocking-poll wrap. See `design/architecture.md` §3.3 for the
> full ledger — refreshed at #46.
>
> **ENH-008 (#35) landed: the shell persists its history to disk.**
> `shell_main` now opens `~/.history/<session>-<ts>.pdxhist` at
> startup via `sys_open(O_WRONLY|O_CREAT|O_APPEND)` (guarded by
> `--no-history`), drains the encoded HistoryEntry ring to disk via
> `sys_write` after every REPL step, and closes the fd on EOF. The
> R106.M1 persistent-home substrate (paideia-os #2228) is what the
> writer sys_opens into. The `ts` argument is passed as `session_id`
> twice today because no `sys_clock_read_ns` wrapper exists in the
> SC+ floor at ENH-008 landing time; a one-line fix at the shell_main
> call site lands when a clock syscall does. The paideia-os side
> still needs a paired landing (add the `shell` satellite as a
> submodule + wire `bin_seeds.pdx`) before the exec cutover named in
> `design/roadmap/rows-4-5-6-scoping.md` §4.2 fires; that paired
> landing is a paideia-os change, not a shell satellite change. The
> reboot-persistence invariant ("run a command, reboot, observe the
> record") is a runtime property proved by the paideia-os boot
> smoke, not this repo. See `design/enhancement-plan.md` §1 for the
> original grep-verified audit and §6 for why the release that first
> executes a command is numbered `v2.0`, not `v0.2` (shell#37 /
> ENH-010).

**Current milestone:** R73 — job control (bg/fg/jobs) + tab completion
**Version:** 0.2.0 (see `CHANGELOG.md`)
**Wave plan:** paideia-os `design/roadmap/persistent-home-wave.md` §R106
**Identity model:** paideia-os `design/user/content-addressed-identity.md`

## R106 progress

Placeholder — each row lands as its issue closes.

| ID              | Title                                                  | State   |
|-----------------|--------------------------------------------------------|---------|
| R106.SHELL-001  | scaffold consolidation (.gitignore, README, STATUS, CHANGELOG) | LANDED  |
| R106.SHELL-002  | tokenizer novel-tilde + bare-cd errors + dispatch entrypoint (#41) | pending |
| R106.SHELL-003  | tokenizer + dispatcher test infrastructure (#42)       | LANDED  |
| shell#44        | sys_fork syscall floor bump + live spawn fingerprint (unblocks #32 close) | LANDED  |
| shell#32        | ENH-005 real exec path (EX_STUB retirement)             | LANDED  |
| shell#24        | R73.M1-004 jobs builtin                                 | LANDED  |
| shell#23        | R73.M1-003 bg/fg builtins (sys_kill SIGCONT + wait4)    | LANDED  |
| shell#22        | R73.M1-002 process-group ^Z in raw mode                 | partial (job-table wired, ^Z blocked pending kernel sys_sigaction or non-blocking wait4) |
| shell#25        | R73.M1-005 tab completion (/bin argv[0], cwd argv[1..]) | LANDED  |

Cross-repo pair: paideia-os R106.M4-KERNEL (kernel-side integration
surface).

---

## Historical: R49 (Wave 1) — v1.0.0

**Prior wave:** R49 (Wave 1)
**Prior milestone:** M5 (1.0 signed release) — encoder half + doc source landed; substrate deferred
**Prior version:** 1.0.0
**Release tag:** `v1.0.0`

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
- `src/line_reader.pdx` (issue #2 skeleton, real read at ENH-007
  #34): `LineReader` module. `line_reader_read_line(buf, buf_len)`
  reads real bytes from fd 0 via a byte-at-a-time `sys_read` loop
  behind a single seam (`lr_read_one_byte`); returns bytes-written
  (includes trailing newline), or `LR_ERR_BAD_BUF` /
  `LR_ERR_EOF` (0-byte read at start) / `LR_ERR_READ_FAIL`
  (negative errno). `LR_STUB` retired at ENH-007.
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

## M4 — tests + smoke matrix (complete, encoder half)

- `tests/test_caps_narrow.pdx` (issue #12, M4-001): `TestCapsNarrow`
  module — 8 test cases against `Exec.exec_narrow_child_caps`
  (HAPPY, NARROWING, MISSING, WIDENING, SIDECAR_FULL, ZERO_DECL,
  BAD_ARGV_PARENT, BAD_ARGV_DECL). Fixture buffers in .bss with
  poison sentinel 0xDEADBEEF at dst[0] for "reject leaves dst
  untouched" verification. Umbrella driver `tcn_run_all` returns 0
  on all-pass or a 0xFFFFED0x fail code.
- `tests/test_audit_first.pdx` (issue #13, M4-002): `TestAuditFirst`
  module — 8 test cases against `CommandRecord.command_record_begin`
  and `command_record_close` (BEGIN_OK, CLOSE_EXIT0, CLOSE_EXIT1,
  CLOSE_NO_BEGIN, CLOSE_EXIT_OOR, BEGIN_ID_ZERO, CLOSE_PENDING,
  ORDERING). Argv fixture "ls\0-l\0" (6 bytes). Umbrella driver
  `taf_run_all` returns 0 or 0xFFFFED1x.
- `tests/test_smoke_matrix.pdx` (issue #14, M4-003):
  `TestSmokeMatrix` module — 4 encoder-half fixtures for the
  `ls | cat` QEMU smoke. Pipeline (2 stages), ls CommandRecord
  (audit_id 0x1001), cat CommandRecord (audit_id 0x1002), history
  ("ls | cat" 8 bytes). Golden bytes derived by hand from the wire
  specs; every expected value pinned in-source as
  `mov r11, imm64; cmp rax, r11`. Umbrella driver `tsm_run_all`
  returns 0 or 0xFFFFED2x. Substrate half (booted QEMU +
  interactive `login → prompt → run → reboot → history` scripted
  run) lives on the paideia-os side, gated on this module's
  `tsm_run_all` return.

**M4 test-code additions to the return-code band 0xFFFFEDxx**
(disjoint from the shell's own 0xFFFFECxx band so an operator
reading a test-run log distinguishes "SUT rejected input" from
"test framework detected the SUT did the wrong thing"):

| Code       | Name                | Meaning                                            |
|------------|---------------------|----------------------------------------------------|
| 0xFFFFED01 | TCN_FAIL_HAPPY      | M4-001: happy case failed                          |
| 0xFFFFED02 | TCN_FAIL_NARROWING  | M4-001: narrowing case failed                      |
| 0xFFFFED03 | TCN_FAIL_MISSING    | M4-001: missing-cap case failed                    |
| 0xFFFFED04 | TCN_FAIL_WIDENING   | M4-001: widening case failed                       |
| 0xFFFFED05 | TCN_FAIL_SIDECAR    | M4-001: sidecar-overflow case failed               |
| 0xFFFFED06 | TCN_FAIL_ZERO_DECL  | M4-001: zero-decl case failed                      |
| 0xFFFFED07 | TCN_FAIL_BAD_ARGV_P | M4-001: null-parent case failed                    |
| 0xFFFFED08 | TCN_FAIL_BAD_ARGV_D | M4-001: null-child_decl case failed                |
| 0xFFFFED09 | TCN_FAIL_DST_MUTATED| M4-001: any reject left dst poison sentinel gone   |
| 0xFFFFED11 | TAF_FAIL_BEGIN_OK   | M4-002: begin happy case failed                    |
| 0xFFFFED12 | TAF_FAIL_CLOSE_E0   | M4-002: close(exit=0) case failed                  |
| 0xFFFFED13 | TAF_FAIL_CLOSE_E1   | M4-002: close(exit=1) case failed                  |
| 0xFFFFED14 | TAF_FAIL_NO_BEGIN   | M4-002: close-without-begin case failed            |
| 0xFFFFED15 | TAF_FAIL_EXIT_OOR   | M4-002: close(exit=256) case failed                |
| 0xFFFFED16 | TAF_FAIL_ID_ZERO    | M4-002: begin(audit_id=0) case failed              |
| 0xFFFFED17 | TAF_FAIL_EXIT_PEND  | M4-002: close(exit=PENDING sentinel) case failed   |
| 0xFFFFED18 | TAF_FAIL_ORDER      | M4-002: begin+close round-trip case failed         |
| 0xFFFFED21 | TSM_FAIL_PIPELINE   | M4-003: pipeline_plan returned non-zero            |
| 0xFFFFED22 | TSM_FAIL_LS_BEGIN   | M4-003: ls begin/close returned non-zero           |
| 0xFFFFED23 | TSM_FAIL_CAT_BEGIN  | M4-003: cat begin/close returned non-zero          |
| 0xFFFFED24 | TSM_FAIL_HIST       | M4-003: history_encode_record returned non-zero    |
| 0xFFFFED25 | TSM_FAIL_PIPELINE_GLD | M4-003: pipeline bytes != golden                 |
| 0xFFFFED26 | TSM_FAIL_LS_GOLDEN  | M4-003: ls record bytes != golden                  |
| 0xFFFFED27 | TSM_FAIL_CAT_GOLDEN | M4-003: cat record bytes != golden                 |
| 0xFFFFED28 | TSM_FAIL_HIST_GOLDEN| M4-003: history bytes != golden                    |

## M3 — semantic-pipe + audit integration (complete)

- `src/pipe_passthrough.pdx` (issue #9, M3-001): `PipePassthrough`
  module — `pipe_passthrough_forward(src, src_len, dst, dst_max)`
  copies one R20b frame (8-byte header + payload_len bytes) from
  src to dst verbatim. D2-literal semantic-pipe passthrough — the
  shell does not decode, re-hash, or otherwise touch the schema
  bytes. `passthrough_bytes_forwarded` singleton records the copy
  size for the caller's cursor advance.
- `src/completion.pdx` (issue #10, M3-002): `Completion` module —
  `completion_encode_record(dst, dst_len, name_ptr, name_len,
  kind, score)` builds one `CommandCompletion` record per SH-D7
  (16-byte fused header + UTF-8 name + 0..7 zero pad). Kind
  vocabulary closed at M3: COMMAND/FILE/DIR/OPTION/SCHEMA.
- `src/command_record.pdx` (issue #11, M3-003): `CommandRecord`
  module — two-phase audit encoder. `command_record_begin` writes
  the OPEN record (48-byte header with `CMDR_EXIT_PENDING =
  0xFFFFFFFF` sentinel + argv text + pad) BEFORE sys_execve;
  `command_record_close` updates ts_end_ns + exit_code + CLOSED
  (+ HAS_ERROR when exit != 0) AFTER sys_wait4. Per D3 audit-first:
  the begin record must be durable before the child emits any
  user-visible output.
- `src/shell.pdx`: stats table grew from 8 to 16 slots (still
  cache-line aligned; two lines). Three new counters:
  `SH_ST_PASSTHRU = 8`, `SH_ST_COMPLETIONS = 9`, `SH_ST_AUDITS =
  10`. Reserved slots 11..15 are zero-initialised for M4/M5.
  `shell_reset`, `shell_note`, `shell_stat` bound compares widened
  from 8 to 16.

## Return-code band 0xFFFFECxx

| Code       | Name              | Meaning                                                    |
|------------|-------------------|------------------------------------------------------------|
| 0xFFFFEC00 | SH_OK             | General success (unused at M1)                             |
| 0xFFFFEC10 | (retired)         | was LR_STUB; retired at ENH-007 (#34); value unallocated   |
| 0xFFFFEC11 | LR_ERR_BAD_BUF    | buf == 0 or buf_len == 0                                   |
| 0xFFFFEC12 | LR_ERR_TTY_UNBOUND| reserved: cap-typed KIND_TTY(read) seat not yet provisioned (paideia-os#1986 landed the op but KIND_TTY absent from KIND_SEEDABLE_TABLE + no shell-side TTY row seed at boot; see architecture.md §3.3) |
| 0xFFFFEC13 | LR_ERR_EOF        | LineReader.ENH-007: sys_read returned 0 with no bytes read |
| 0xFFFFEC14 | LR_ERR_READ_FAIL  | LineReader.ENH-007: sys_read returned a negative errno     |
| 0xFFFFEC20 | EX_STUB           | Exec.M1 (retired at ENH-005): validated, no live spawn     |
| 0xFFFFEC21 | EX_ERR_BAD_ARGV   | Exec: pool == 0, argv_bytes == 0, or argc == 0 (ENH-005)   |
| 0xFFFFEC22 | EX_ERR_EXECVE_FAIL| Exec.ENH-005: sys_execve returned (never returns on success) |
| 0xFFFFEC23 | EX_ERR_WAIT_FAIL  | Exec.ENH-005: sys_wait4 returned negative errno            |
| 0xFFFFEC24 | EX_ERR_MISSING_CAP| Exec.M2: child requires a KIND not in parent's cap set     |
| 0xFFFFEC25 | EX_ERR_WIDENING   | Exec.M2: child asks for rights parent does not hold        |
| 0xFFFFEC26 | EX_ERR_SIDECAR_FULL| Exec.M2: dst buffer too small for narrowed sidecar        |
| 0xFFFFEC27 | EX_ERR_ARGV_OVERFLOW    | Exec.ENH-005: build_argv_ptrs argc + 1 > dst_max (>= 16)    |
| 0xFFFFEC28 | EX_ERR_AUDIT_BEGIN_FAIL | Exec.ENH-005: command_record_begin refused (D3 audit-first gate) |
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
| 0xFFFFEC70 | PP_ERR_BAD_ARGS   | PipePassthrough.M3: src/dst null, dst_max 0, or src_len<8  |
| 0xFFFFEC71 | PP_ERR_TRUNCATED  | PipePassthrough.M3: src_len < 8+payload_len                |
| 0xFFFFEC72 | PP_ERR_DST_OVERFLOW | PipePassthrough.M3: dst_max < 8+payload_len              |
| 0xFFFFEC73 | PP_ERR_OVERSIZED  | PipePassthrough.M3: payload_len > 0x7FFFFFF7               |
| 0xFFFFEC80 | COMP_ERR_BAD_ARGS | Completion.M3: dst/name null or kind/score out of range    |
| 0xFFFFEC81 | COMP_ERR_TOO_LONG | Completion.M3: name_len > 512 (COMP_NAME_MAX)              |
| 0xFFFFEC82 | COMP_ERR_TRUNCATED| Completion.M3: dst_len < required record size              |
| 0xFFFFEC83 | COMP_ERR_EMPTY_NAME | Completion.M3: name_len == 0                             |
| 0xFFFFEC90 | CMDR_ERR_BAD_ARGS | CommandRecord.M3: dst null, audit_id 0, or argv null w/len |
| 0xFFFFEC91 | CMDR_ERR_TOO_LONG | CommandRecord.M3: argv_bytes > 8192 (CMDR_ARGV_MAX)        |
| 0xFFFFEC92 | CMDR_ERR_TRUNCATED| CommandRecord.M3: dst_len < required record size           |
| 0xFFFFEC93 | CMDR_ERR_BAD_EXIT | CommandRecord.M3: exit_code > 255 (close only)             |
| 0xFFFFECA0 | RM_ERR_BAD_ARGS   | ReleaseManifest.M5: dst == 0, dst_len == 0, or offset >= dst_len |
| 0xFFFFECA1 | RM_ERR_TRUNCATED  | ReleaseManifest.M5: dst too small for header / KV / sigblock slot |
| 0xFFFFECA2 | RM_ERR_KV_TOO_LONG | ReleaseManifest.M5: kv value_len > 65535 (RM_KV_LEN_MAX)  |
| 0xFFFFECA3 | RM_ERR_SIG_TOO_LONG | ReleaseManifest.M5: sig_len > 8192 (RM_SIG_LEN_MAX)     |
| 0xFFFFECB0 | BB_STUB           | BrokerBind.M5: encoder validated; sys_ipc_send deferred    |
| 0xFFFFECB1 | BB_ERR_BAD_ARGS   | BrokerBind.M5: dst/endpoint/name null or name_len == 0     |
| 0xFFFFECB2 | BB_ERR_NAME_TOO_LONG | BrokerBind.M5: name_len > 256 (BB_NAME_MAX)             |
| 0xFFFFECB3 | BB_ERR_TRUNCATED  | BrokerBind.M5: dst_len < required record size              |
| 0xFFFFECC0 | LX_ERR_OVERFLOW           | Lexer.ENH-002: > 128 tokens (TOK_MAX_PER_LINE)     |
| 0xFFFFECC1 | LX_ERR_UNTERMINATED_QUOTE | Lexer.ENH-002: `'..'` or `".."` not closed         |
| 0xFFFFECC2 | LX_ERR_INVALID_ESCAPE     | Lexer.ENH-002: trailing `\` at end of input        |
| 0xFFFFECC3 | LX_ERR_BAD_ARGS           | Lexer.ENH-002: input_ptr == 0 && input_len > 0     |
| 0xFFFFECD0 | PR_ERR_TOO_MANY_STAGES    | Parser.ENH-003: > 8 pipeline stages (PR_MAX_STAGES) |
| 0xFFFFECD1 | PR_ERR_LEADING_PIPE       | Parser.ENH-003: line begins with `\|`               |
| 0xFFFFECD2 | PR_ERR_TRAILING_PIPE      | Parser.ENH-003: line ends with `\|`                 |
| 0xFFFFECD3 | PR_ERR_EMPTY_STAGE        | Parser.ENH-003: two `\|` with no words between      |
| 0xFFFFECD4 | PR_ERR_ARGV_POOL_OVERFLOW | Parser.ENH-003: words exceed 4096-byte argv pool    |
| 0xFFFFECE0 | BI_MISS                   | Dispatch.ENH-004: argv[0] matched no builtin (try external) |
| 0xFFFFECE1 | BI_ERR_CD_NO_ARG          | Builtins.ENH-004: `cd` invoked with no path argument |
| 0xFFFFECE2 | BI_ERR_CD_FAIL            | Builtins.ENH-004: sys_chdir returned negative errno |
| 0xFFFFECE3 | BI_ERR_EXIT_BAD_CODE      | Builtins.ENH-004: `exit` argv[1] does not start with a digit |
| 0xFFFFECE4 | BI_ERR_EXPORT_MALFORMED   | Builtins.ENH-004: `export` argv[1] has no '=' or empty name |
| 0xFFFFECE5 | BI_ERR_EXPORT_TABLE_FULL  | Builtins.ENH-004: shell-local env table at BI_ENV_TABLE_MAX (32) |
| 0xFFFFECE6 | BI_ERR_EXPORT_POOL_FULL   | Builtins.ENH-004: name+value would exceed 4096-byte env pool |
| 0xFFFFECE7 | BI_ERR_PWD_TOO_LONG       | Builtins.ENH-004: sys_getcwd returned negative errno |
| 0xFFFFECF0 | SM_ERR_ARG_FLAG_UNKNOWN   | shell_main.ENH-006: unknown CLI flag (`--foo`, or `-c` without command) |
| 0xFFFFECF1 | SM_ERR_LINE_TOO_LONG      | shell_main.ENH-006: reserved for future explicit read-overflow surface (ENH-007 chose partial-line return instead) |
| 0xFFFFECF2 | SM_ERR_SESSION_MINT_FAIL  | shell_main.ENH-006: session_mint refused at startup |
| 0xFFFFECF3 | SM_ERR_DISPATCH_INIT_FAIL | shell_main.ENH-006: reserved (dispatch_init returns () today) |
| 0xFFFFECF8 | SR_EOF                    | shell_repl_step.ENH-006: reserved for future explicit EOF signal |

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
| M3-001 (#9)     | semantic-pipe passthrough: child schema forwarded unchanged (D2 literal) | LANDED |
| M3-002 (#10)    | CommandCompletion[] schema for tab-completion (SH-D7)            | LANDED |
| M3-003 (#11)    | ShellCommandRecord via libpdx-audit before sys_execve; close on wait | LANDED |
| M4-001 (#12)    | caps-narrowing violation matrix (child receives cap not in caps.decl → reject) | LANDED |
| M4-002 (#13)    | audit-first invariant test (child cannot emit before audit is durable) | LANDED |
| M4-003 (#14)    | QEMU smoke: login → prompt → `ls | cat` → history persists across reboot (encoder half) | LANDED |
| M5-001 (#15)    | dual-signed release (manifest.pdxsig encoder + placeholder sigblock) + svc.login-shell broker registration | LANDED |
| M5-002 (#16)    | .pdxdoc for doc shell (doc/shell.pdxdoc + design/pdxdoc-source.md) + mirror-push protocol (design/mirror-push.md) | LANDED |

## M5 — 1.0 signed release (complete, encoder half + doc source + design contracts)

- `src/release_manifest.pdx` (issue #15, M5-001): `ReleaseManifest`
  module — encoder for pkg §4 `manifest.pdxsig`. Four entry points
  (`release_manifest_encode_header_prefix`, `_header_suffix`,
  `release_manifest_encode_kv`, `release_manifest_encode_sigblock_slot`)
  assemble the header + eleven-tag body + sigblock in one linear
  pass. Sigblock zero-fill path pins the two ML-DSA-65 signature
  slots at their release-form offsets while the crypto substrate
  (paideia-as v0.33-crypto-kdf) is out of reach.
- `src/broker_bind.pdx` (issue #15, M5-001): `BrokerBind` module —
  `broker_bind_login_shell(dst, dst_len, endpoint_cap, name_ptr,
  name_len, rights_mask)` writes the three-qword BrokerBindRequest
  header (BB_MAGIC | rec_len fused, endpoint_cap, rights_mask |
  name_len fused) + UTF-8 name + zero-padding, then returns
  `BB_STUB` (0xFFFFECB0). The M4+ substrate `sys_ipc_send` wrapper
  invokes this encoder at shell boot.
- `manifest.pdxproj`: version 0.4.0-m4 → 1.0.0; adds
  `release_manifest.pdx` + `broker_bind.pdx` to sources,
  `test_release_manifest.pdx` to tests, `doc/shell.pdxdoc` to docs;
  new `release:` block names the two signers + broker name + mirror
  target.
- `CHANGELOG.md` (new): v1.0.0 entry + rollup of the four
  pre-release milestones.
- `tests/test_release_manifest.pdx` (issue #15, M5-001):
  `TestReleaseManifest` module — 4-case encoder-golden matrix
  (`trm_case_hdr_prefix`, `trm_case_hdr_suffix`, `trm_case_kv`,
  `trm_case_broker_bind`) driven by `trm_run_all`. Fail-code band
  0xFFFFED3x. Release-lint pre-sign gate.
- `doc/shell.pdxdoc` (issue #16, M5-002): the doc source for
  `doc shell`. Front-matter block + 11 body sections (SYNOPSIS,
  DESCRIPTION, OPTIONS, EXAMPLES, FILES, ENVIRONMENT,
  EXIT_STATUS, DIFFERENCES_FROM_POSIX, SEE_ALSO,
  CAPABILITIES_REQUESTED, SIGNING) per
  `design/pdxdoc-source.md` §3.
- `design/release-manifest.md` (issue #15, M5-001): shell-specific
  view of the pkg-wide manifest format — which tags shell emits, in
  what order, with what values; sigblock placeholder scheme;
  release-lint sequence.
- `design/pdxdoc-source.md` (issue #16, M5-002): the `.pdxdoc`
  source-file conventions the doc.M1-002 parser is expected to
  consume.
- `design/mirror-push.md` (issue #16, M5-002): the
  `pkgs.paideia-os` mirror-push protocol — file tree layout,
  `index.pdxsig` row shape, atomic-push discipline.

**M5 test-code additions to the return-code band 0xFFFFEDxx**
(disjoint from the shell's own 0xFFFFECxx and the M4 test bands):

| Code       | Name                    | Meaning                                            |
|------------|-------------------------|----------------------------------------------------|
| 0xFFFFED30 | TRM_FAIL_HDR_PREFIX     | M5-001: header prefix golden mismatch              |
| 0xFFFFED31 | TRM_FAIL_HDR_SUFFIX     | M5-001: header suffix golden mismatch              |
| 0xFFFFED32 | TRM_FAIL_KV             | M5-001: KV record golden mismatch                  |
| 0xFFFFED33 | TRM_FAIL_BROKER_BIND    | M5-001: broker-bind golden mismatch                |
| 0xFFFFED34 | TRM_FAIL_HDR_PREFIX_RC  | M5-001: header prefix return code mismatch         |
| 0xFFFFED35 | TRM_FAIL_HDR_SUFFIX_RC  | M5-001: header suffix return code mismatch         |
| 0xFFFFED36 | TRM_FAIL_KV_RC          | M5-001: KV record return code mismatch             |
| 0xFFFFED37 | TRM_FAIL_BROKER_BIND_RC | M5-001: broker-bind return code mismatch           |

## Upstream substrate (paideia-os, corrected shell#37 / ENH-010)

The section below was four days stale as of its original writing and
is the reason the encoder-vs-shell gap went unexamined for as long as
it did: it listed KIND_TTY, real `sys_execve`, `sys_wait4`, and
PdxFS-write as still-open substrate gaps after they had already
landed upstream.

- `KIND_USER = 0x190` — landed at R48.M1-001 (`kind_user.pdx`).
- `KIND_TTY` — landed. No longer a provisional ordinal; the collision
  with `KIND_PDXFS_TXN` this section used to flag is resolved.
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
- Userspace `sys_execve` — landed at R62, with real argv/envp (no
  longer the R17-era stub this section used to wait on).
- Userspace `sys_wait4` — landed.
- Userspace `sys_chdir` / `sys_getcwd` (sysno 85/86) — landed at R86.
- Userspace PdxFS-write path — landed.

## Sibling libraries (all landed today)

- libpdx-cap.M2 — cap_pack_narrowed + cap_manifest_verify + cap_unpack_checked
- libpdx-semantic-pipe.M2 — passthrough + envelope
- libpdx-argv.M2 — typed flags + std vocab
- libpdx-audit.M2 — audit sender path
- libpdx-elevate.M2 — auto-approve + human-approve + Cap<> with lifetime
  (declared as a shell build dependency but never linked — see
  `design/enhancement-plan.md` §5 / ENH-009, #36).

**Prior walk-back on this section (retained for continuity).** The
text below was written when the shell was still a wire-format encoder
suite. ENH-001 (#28), ENH-002 (#29), ENH-003 (#30), ENH-004 (#31),
ENH-005 (#32), and now ENH-006 (#33) invalidate every bullet:

- No syscall instruction anywhere in `src/` (ENH-001, #28) — every
  item below is blocked on this one absence. **LANDED at #28.**
- No lexer / tokenizer (ENH-002, #29) and no parser (ENH-003, #30) —
  nothing derives `pipeline_plan`'s `stages_count` from text.
  **LANDED at #29 / #30.**
- No builtin dispatch table — no `cd`, `pwd`, `export`, or `exit`
  handler exists (ENH-004, #31). **LANDED at #31.**
- `exec_spawn_and_wait` still returns `EX_STUB` — the real
  execve/wait4 sequence is unwritten (ENH-005, #32). **LANDED at
  #32.**
- `Shell::shell_main` — the entry symbol `manifest.pdxproj` has
  declared since M1 — is not defined anywhere in the repository
  (ENH-006, #33). **LANDED at #33 (this commit): src/shell.pdx
  defines shell_main + shell_repl_step + shell_argv_dispatch;
  manifest.pdxproj `kind` flips back to `tool`.**
- `line_reader_read_line` now reads real bytes from fd 0 behind
  the `lr_read_one_byte` seam (ENH-007, #34) **LANDED at #34**;
  `history_encode_record`'s bytes are drained to
  `~/.history/<session>-<ts>.pdxhist` via `sys_write` after every
  REPL step (ENH-008, #35) **LANDED at #35**; the M3-002
  tab-completion encoder has no registry walk or tab-key binding
  behind it (ENH-009, #36) — still open.
- Cross-repo linkage (shell → libpdx-cap / libpdx-semantic-pipe /
  libpdx-audit symbols) — no build pulls all sides together yet.
  **Still open.**

## Next

The R49 wave closed with the encoder half described above, not with a
working shell, and did not open at R56+ — no pause followed it. Two
milestones are open concurrently today:

- **R106 — shell scaffolding + tokenizer novel semantics**
  (paideia-os `design/roadmap/persistent-home-wave.md` §R106).
  R106.SHELL-001 (scaffold consolidation) is landed; R106.SHELL-002
  (tokenizer, #41) and R106.SHELL-003 (test infra, #42) are open. See
  the R106 progress table above.
- **`v2.0 — real exec substrate`** (milestone #8,
  `design/enhancement-plan.md`) — the plan that makes `shell` able to
  execute a command for the first time. Critical path: ENH-001
  syscall floor (#28) → ENH-002 lexer (#29) → ENH-003 parser (#30) →
  ENH-004/ENH-005 builtins + real exec (#31/#32) → **ENH-006
  `Shell::shell_main` + REPL (#33) LANDED → ENH-007 line reader
  real bytes (#34) LANDED**. ENH-008/009 (#35-#36) de-stub the
  history persistence and libpdx-elevate behind that path.
  ENH-010 (#37, this walk-back) and ENH-011 (#38, correcting the
  R66/R73 issue bodies + the line-editing polish tier tracked at
  #17-#21) carry no dependencies and land independently.

The M5-001 encoder half + M5-002 doc source + design contracts remain
what the release-time lint (once paideia-as reaches v0.33-crypto-kdf
and ENH-005/ENH-009 land a real broker `sys_ipc_send`) signs and
re-pushes to `pkgs.paideia-os/main/shell/1.0.0/`. The M4 encoder-half
tests (`tcn_run_all`, `taf_run_all`, `tsm_run_all`) plus the M5
addition (`trm_run_all`) and the ENH-006 addition (`tshm_run_all`)
are what that lint re-runs to confirm no regression against the
golden fingerprints; the interactive QEMU smoke (`login → prompt →
ls | cat → reboot → history`) is now boot-reachable — the shell's
own side is done, and the paired paideia-os landing (add the shell
satellite as a submodule + wire `bin_seeds.pdx`) is what fires the
interactive cutover named in
`design/roadmap/rows-4-5-6-scoping.md` §4.2.
