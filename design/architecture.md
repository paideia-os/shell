# shell — architecture

**Wave:** R49 (Wave 1)
**Repo:** github.com/paideia-os/shell
**Upstream design:** `design/tooling/r49-r50-plan.md` §5.2 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of the shell binary. It does
not repeat the wave-level rationale from the paideia-os plan doc; read
that first for D2 (semantic pipes), D3 (audit-first), D4 (signed
manifests), and I6 (capability handoff visible + refusable). The shell
is the process that reads user commands, spawns tool processes with the
caller's cap environment narrowed per each callee's caps.decl, and
threads text-and-schema-and-cap layers through pipes.

## 1. Public surface

The shell is not a library — it is a binary. Its "surface" from a
programmatic point of view is a small set of module entry points the
ELF entry (`Shell::shell_main`, per `manifest.pdxproj`) calls in order:

- `Shell` (`src/shell.pdx`) — top-level orchestration, constants shared
  across the shell's modules, session-level state (bounded stats table,
  reset function), and — as of ENH-006 (#33) — the ELF entry
  `shell_main`, the CLI flag walker `shell_argv_dispatch`, the one-line
  REPL step `shell_repl_step`, and the byte-string helpers (`sm_strlen`,
  `sm_streq_lit`, `sm_str_prefix`) the walker consumes.
- `LineReader` (`src/line_reader.pdx`) — the interactive line reader.
  Exposes `line_reader_read_line(buf, buf_len) → u64`; internally
  reads one byte at a time from fd 0 via `sys_read(0, ptr, 1)` behind
  a single seam (`lr_read_one_byte`). Real at ENH-007 (#34); the LR_STUB
  M1 tail is retired. The cap-typed KIND_TTY(read) invoke is deferred
  behind the same seam until paideia-os#1986 lands KIND_TTY_OP_READ
  (see §3.3 below for the rationale). `shell_main` treats a bare 0,
  `LR_ERR_EOF`, `LR_ERR_READ_FAIL`, and `LR_ERR_BAD_BUF` (defensive)
  as EOF signals so the REPL terminates cleanly on any non-line return.
- `Exec` (`src/exec.pdx`) — the exec path. `exec_spawn_and_wait(pool,
  bytes, argc) → u64` marshals argv from the parser's pool slice,
  narrows the child's cap set against the parent's, opens an audit
  record BEFORE `sys_execve`, then blocks on `sys_wait4`. Real at
  ENH-005 (#32); the sole substrate-scope gap remaining is the
  fork-vs-execve pattern (see the module's §FORK GAP note).
- `Lexer` / `Parser` / `Dispatch` / `Builtins` (`src/lexer.pdx` /
  `src/parser.pdx` / `src/dispatch.pdx` / `src/builtins.pdx`) —
  landed at ENH-002..ENH-004 (#29 / #30 / #31). Together they consume
  a line of bytes and produce either a matched builtin invocation
  (bi_cd / bi_exit / bi_export / bi_pwd) or `BI_MISS` for the REPL
  to route to `exec_spawn_and_wait`.

### 1.1 REPL loop

`Shell::shell_main` (ELF entry, `@no_frame`) reads argc + argv from
the SysV initial process stack (argc at `[rsp+0]`, argv qwords at
`[rsp+8..]`, `argv[argc]==NULL`), populates the `_sm_opt_*` singletons
via `shell_argv_dispatch`, runs `dispatch_init` + `session_mint`
(into `_sm_session_cap`), then enters this loop:

```
loop:
    sys_write(1, "$ ", 2)                          // prompt
    let n = LineReader::line_reader_read_line(_sm_line_buf, 4096)
    if n in { 0, LR_ERR_EOF, LR_ERR_READ_FAIL, LR_ERR_BAD_BUF }:
        sys_write(1, "\n", 1); sys_exit(0)         // EOF path
    if n > 4096: sys_exit(0)                       // defensive
    let rc = Shell::shell_repl_step(_sm_line_buf, n)
    if not _sm_opt_no_history:
        History::history_encode_record(
            &_sm_hist_buf[_sm_hist_used],
            8192 - _sm_hist_used,
            _sm_line_buf, n, ts_ns=0, flags=0)
        _sm_hist_used += history_bytes_written    // if OK
```

`shell_repl_step(line_ptr, line_len)` runs one pipeline stage
(stage[0]; multi-stage fan-out is future work) through
`Lexer::lexer_tokenize` -> `Parser::parser_parse` ->
`Dispatch::dispatch_line`. On `BI_MISS` it derives a
`KIND_SHELL_SESSION` sub-cap into `_sm_child_cap` via
`Session::session_derive_subcap` (the child cap the future InitCap
sidecar handoff will carry; see `src/exec.pdx` §DEFERRALS) then
invokes `Exec::exec_spawn_and_wait` with the parser's pool slice.
Empty and whitespace-only lines short-circuit to `SR_OK` without
touching the exec path.

The `-c <command>` one-shot path bypasses the loop: `shell_main`
calls `shell_repl_step` once with the recorded command bytes, then
`sys_exit(0)`. This matches the POSIX `-c` semantics without
carrying the interactive prompt discipline.

### 1.2 CLI options

`shell_argv_dispatch` walks argv[1..argc] and populates `_sm_opt_*`
singletons per the following table. Any argv[i] beginning with `-`
that does not match one of the two recognised long flags or the
single-dash `-c` form returns `SM_ERR_ARG_FLAG_UNKNOWN` (0xFFFFECF0);
`shell_main` writes `shell: unknown flag\n` to stderr and
`sys_exit(1)`.

| Flag                 | Populates                                                                |
|----------------------|--------------------------------------------------------------------------|
| `-c <command>`       | `_sm_opt_c_cmd_ptr` (argv[i+1]) + `_sm_opt_c_cmd_len` (strlen)          |
| `--no-history`       | `_sm_opt_no_history = 1`                                                 |
| `--no-cap:<KIND>`    | `_sm_opt_no_cap_kind = 1` (KIND parse + cap-narrowing hook deferred)     |
| `<positional>`       | `_sm_opt_script_ptr` (last one wins; `.pds` script dispatcher deferred)  |

Session-cap wiring at startup: `shell_main` calls `session_mint`
into `_sm_session_cap` with `SM_SESSION_ID = 1` (placeholder;
real session ids arrive when runtime cap-table introspection lands).
`shell_repl_step` calls `session_derive_subcap` into `_sm_child_cap`
before each external exec so the derivation is exercised end-to-end,
even though the sidecar consumer inside `sys_execve` is a documented
deferral (see `src/exec.pdx` §DEFERRALS step 2).

## 2. `Shell` module (src/shell.pdx)

### 2.1 Constants

The Shell module owns:

- **KIND ordinal mirrors.** The kernel's KIND ordinals the shell talks
  about (`SH_KIND_USER = 0x190`, `SH_KIND_IPC_ENDPOINT = 5`,
  `SH_KIND_SHELL_SESSION = 0x194`, `SH_KIND_PDXFS_FILE = 0x195`,
  `SH_KIND_ELEVATE_CHANNEL = 0x191`). Redeclared here for the same
  reason libpdx-elevate mirrors ELV_* — the shell repo is not
  obligated to link paideia-os's kernel .o graph at build time. A
  drift caught by the M4 smoke matrix; the `SH_` prefix documents the
  mirror invariant.
- **Return-code band `0xFFFFECxx`.** The shell's own error-code family,
  disjoint from the underlying kernel's syscall errno family
  (`-EFAULT = 0xFFFFFFFFFFFFFFF2` etc.) and from the R49 shared
  libraries' bands (libpdx-cap 0xFFFFFFxx, libpdx-elevate 0xFFFFEAxx,
  libpdx-audit TBD). See §5 for the full table.
- **Session-level `.bss` singleton.** An 8-slot stats counter table
  (`_shell_stats`), cache-line aligned, mirrors the shape of
  `ElevateBroker._elevate_broker_stats` and libpdx-cap's own singletons
  — one entry per observable event class (prompts issued, lines read,
  spawns attempted, exits observed, errors).

### 2.2 `shell_reset()`

Clears the eight-word `_shell_stats` counter table. Called by
`_start` before the run loop and by tests before each fixture. Leaf
function; `r10` as base + `rcx` as loop index. Same shape as
`elevate_broker_stats_reset` (paideia-os `src/kernel/core/ipc/
elevate_broker.pdx:70`) and `elevate_client_stats_reset` in
libpdx-elevate.

### 2.3 `shell_note(which)` + `shell_stat(which)`

Bounded increment + bounded read for the counter table. `which >=
SH_ST_MAX` is a no-op (increment) or returns 0 (read) — a caller
passing a slot from a newer library version against an older linker
snapshot cannot corrupt live counters. Same shape as
`elevate_client_note` / `elevate_client_stat` in libpdx-elevate.

## 2a. `Syscall` module (src/syscall.pdx) — ENH-001 (#28)

### 2a.1 Purpose

The syscall floor. At `v1.0.0` the shell repository contained ZERO
`syscall` instructions; every stub in the tree (`EX_STUB`, `LR_STUB`,
`HIST_STUB`, `BB_STUB`, ...) was blocked on this one absence. ENH-001
lands the SC+ substrate every stage in `design/enhancement-plan.md` §4
consumes: sysno constants + thin callable wrappers for the nine SC+ IDs
the shell v2.0 plan enumerates.

The module lands the floor ONLY. No caller in the repository is wired
up here; the higher-level modules (`Exec`, `LineReader`, `History`,
`BrokerBind`, ...) invoke these wrappers as their respective `_STUB`
tails are de-stubbed in ENH-005 (real exec), ENH-007 (real read),
ENH-008 (PdxFS write), ENH-006 (`shell_main` + `sys_exit`).

### 2a.2 Wrapper surface

```
Syscall::sys_read (fd, buf, count)           -> u64   SC+ ID 0
Syscall::sys_write(fd, buf, count)           -> u64   SC+ ID 1
Syscall::sys_open (path, flags, mode)        -> u64   SC+ ID 2
Syscall::sys_close(fd)                       -> u64   SC+ ID 3
Syscall::sys_execve(path, argv, envp)        -> u64   SC+ ID 59
Syscall::sys_exit(status)                    -> u64   SC+ ID 60 (nrt)
Syscall::sys_wait4(pid, wstatus, opts, ru)   -> u64   SC+ ID 61
Syscall::sys_chdir(path, path_len_hint)      -> u64   SC+ ID 85
Syscall::sys_getcwd(buf, cap)                -> u64   SC+ ID 86
```

The nine sysno constants are exported as `pub let SYS_READ : u64 = 0`
etc. — a single point of authority for the SC+ IDs across the shell
repo, so a future kernel-side renumbering (unlikely: the SC+ table is
frozen post-R15.M4 with §"IDs are negotiable" latitude only) is a
single-file change here rather than an N-callsite grep across every
consumer. The canonical authoritative table lives in the paideia-os
monorepo at `design/user/syscall-table.md`; this module mirrors the
subset the shell needs.

### 2a.3 Calling convention

Every wrapper takes SysV arguments (`rdi, rsi, rdx, rcx, r8, r9`) and
issues `SYSCALL`, which follows the Linux SYSCALL convention (`rdi,
rsi, rdx, r10, r8, r9`). For wrappers of arity ≤ 3 the argument
registers overlap and no shuffle is needed; `sys_wait4` (arity 4) alone
prepends `mov r10, rcx` to relocate SysV arg3 into the SYSCALL arg3
slot.

Each wrapper is a LEAF function: no push/pop, no local stack frame.
`syscall` clobbers `rcx` and `r11` per x86-64 SYSCALL semantics — both
are SysV caller-save, so callers preserve them via SysV convention if
they need them across the call. All other GP registers are preserved by
the kernel.

The effect + capability annotations mirror the monorepo's canonical
`src/user/syscall_shim.pdx` for each corresponding ID. Notably: `mem`
appears wherever the kernel reads or writes the caller's buffers
(`sys_read`/`sys_write`/`sys_getcwd` etc.); `sched` on the two
scheduler-touching wrappers (`sys_execve`, `sys_exit`, `sys_wait4`);
`fs` on the seven fs-facing wrappers; `mem` capability on `sys_execve`
which replaces the process address space.

### 2a.4 Design decision: shared module, not inline per callsite

The monorepo has two established patterns for user-space syscalls:

- **Inline at every callsite.** Used by single-file one-ELF binaries
  (`src/user/cat.pdx:127` explains the pattern verbatim: `child_hello`,
  `true`, `echo_client`, `mkfs.pdxfs/src/main.pdx`). Every one of these
  tools compiles to a single-file ELF; extending the pattern to a
  multi-module program would duplicate the sysno at N callsites and
  multiply the drift surface against the frozen SC+ table.
- **Shared shim linked by multi-object-set consumers.** The canonical
  precedent is `src/user/syscall_shim.pdx` — a 25-wrapper module
  linked by BOTH `init.elf` and (the kernel-tree) `shell.elf`. Every
  wrapper is 3 to 4 instructions; the shared surface makes drift
  auditable at a SINGLE point.

The shell repo has been multi-module since M1 (12 `.pdx` files at
v1.0.0, each producing its own `.o` under `build-out/`, all destined
for a single `shell` ELF at link time). Cross-module `call` linkage is
already the norm — every module in `src/` calls `Shell::shell_note`.
Introducing a shared `Syscall` wrapper set is architecturally
consistent with the existing cross-module wiring and matches the
multi-object-set precedent of `syscall_shim.pdx` rather than the
single-file-ELF inline pattern of `cat.pdx`.

The two patterns are not in conflict; they cover different
architectures. The shell's architecture (multi-module, one ELF) maps
onto the shared-shim pattern by construction.

### 2a.5 Fingerprint (`tests/test_syscall_floor.pdx`)

Two RUNTIME cases in the `0xFFFFED4x` fail-code band prove the shim
shape end-to-end when invoked from a live kernel:

- `tsf_case_getcwd` — `sys_getcwd(buf, 256)` returns a strlen in
  `[1, 255]`. Errno, empty, and out-of-range results each map to a
  distinct sentinel.
- `tsf_case_write` — `sys_write(1, "syscall floor ok\n", 17)` returns
  17. Errno, short, and over-write results each map to a distinct
  sentinel.

Together they exercise `SYSCALL` twice at different sysnos and
different SysV arities (2 and 3), which is enough to catch a regressed
shim. The umbrella `tsf_run_all` matches the `tcn_run_all` /
`taf_run_all` / `tsm_run_all` / `trm_run_all` shape so the future
boot-time smoke harness can invoke all five drivers in one loop.

Unlike the four M4/M5 encoder-half test modules (which are pure-
function fixtures against caller-owned buffers), `TestSyscallFloor`
issues real syscalls when invoked. The compile-clean state remains the
local guarantee at build time; the substrate-half verification lives
in the paideia-os v2.0 smoke loop that will invoke `tsf_run_all` after
a shell binary lands.

## 2b. `Lexer` module (src/lexer.pdx) — ENH-002 (#29)

### 2b.1 Purpose

The missing byte-level split. At `v1.0.0` (and through ENH-001) the
shell repository had no lexer — nothing in `src/` turned a byte buffer
into a token stream. `src/pds.pdx` parses `.pds` HEADERS but never
sees a command line; `src/pipeline.pdx::pipeline_plan` presupposes a
`stages_count` but has no way to derive one from raw bytes. ENH-002
lands the tokenizer every downstream consumer (parser at ENH-003,
builtin dispatch at ENH-004, real exec at ENH-005, REPL at ENH-006)
consumes.

### 2b.2 Contract

```
lexer_tokenize(input_ptr: u64, input_len: u64) -> u64
lexer_reset() -> ()
```

Given a caller-owned byte buffer, produce a token stream in the
module's `.bss` singletons:

- `_lx_tokens : [u64; 384]` — 128 tokens × 3 qwords each (byte offset
  `i*24` = token `i`). Layout per token: qword0 = offset in source
  buffer, qword1 = length in bytes, qword2 = kind discriminator.
- `_lx_token_count : u64` — number of tokens populated on success.
  Written only on the `LX_OK` path; on any error the count is left
  untouched (return code is the authoritative signal).

### 2b.3 Token vocabulary

Fixed set at ENH-002 (extending is a schema-version bump):

- `TOK_WORD      = 1` — a run of non-whitespace, non-operator bytes,
  possibly including quoted or escaped sub-runs that logically belong
  to the same word.
- `TOK_PIPE      = 2` — `|` (0x7C). Pipeline.pipeline_plan consumes.
- `TOK_REDIR_IN  = 3` — `<` (0x3C).
- `TOK_REDIR_OUT = 4` — `>` (0x3E).
- `TOK_SEMI      = 5` — `;` (0x3B).
- `TOK_AMP       = 6` — `&` (0x26).
- `TOK_EOF       = 7` — reserved; never emitted. Caller reads
  `_lx_token_count` for the end.

### 2b.4 Grouping rules

- **Single-quote `'…'`** — bytes between the quotes are literal; no
  expansion, no backslash escape. Missing closing quote →
  `LX_ERR_UNTERMINATED_QUOTE`.
- **Double-quote `"…"`** — bytes are literal except for `\<char>`
  which yields the literal `<char>`. Missing closing quote →
  `LX_ERR_UNTERMINATED_QUOTE`. Trailing `\` inside the quoted region
  → `LX_ERR_INVALID_ESCAPE`.
- **Backslash `\<char>` outside quotes** — the `\` and the following
  byte both belong to the current word. Trailing `\` at end-of-input
  → `LX_ERR_INVALID_ESCAPE`.
- **Adjacency** — quoted / escaped fragments join into ONE word:
  `hello"a b"world` is one WORD token spanning all 15 bytes. `echo
  'a b'` tokenizes as WORD("echo") WORD("'a b'") — two words, because
  the space between them is unquoted. The token's (offset, length)
  span includes the quote bytes themselves; the caller decides
  whether to strip them at expansion time.

### 2b.5 Error codes

- `LX_ERR_OVERFLOW = 0xFFFFECC0` — more than `TOK_MAX_PER_LINE` (128)
  tokens.
- `LX_ERR_UNTERMINATED_QUOTE = 0xFFFFECC1` — `'…` or `"…` never closed.
- `LX_ERR_INVALID_ESCAPE = 0xFFFFECC2` — `\` at end of input (or at
  end of a double-quoted region).
- `LX_ERR_BAD_ARGS = 0xFFFFECC3` — `input_ptr == 0 && input_len > 0`.
  `input_len == 0` is always a valid empty-line case yielding 0
  tokens without ever loading `input_ptr`.

The band `0xFFFFECCx` is the first unused sub-band above BrokerBind
(`0xFFFFECBx`); the issue's suggested `0xFFFFEC5x` collides with the
existing Pds allocation.

### 2b.6 Substrate deferral

None. The lexer is a pure-function transformer over caller-owned
bytes; it makes no syscall and touches no substrate. This is what
lets it land BEFORE any of ENH-003 through ENH-006 (parser through
REPL) that will consume its output.

### 2b.7 Fingerprint (`tests/test_lexer.pdx`)

Seven cases in the `0xFFFFED5x` fail-code band cover the tokenization
surface:

- `tlx_case_bare_ls` — `ls` → 1 WORD(0, 2).
- `tlx_case_ls_l` — `ls -l` → WORD(0, 2) WORD(3, 2).
- `tlx_case_pipe` — `ls | cat` → WORD PIPE WORD.
- `tlx_case_pipe_redir` — `ls | cat > /tmp/f` → WORD PIPE WORD
  REDIR_OUT WORD.
- `tlx_case_quoted` — `echo 'a b'` → WORD(0, 4) WORD(5, 5) — the
  quoted region including its quote bytes is ONE word.
- `tlx_case_empty` — `len == 0` → 0 tokens, LX_OK.
- `tlx_case_ws_only` — `"   "` → 0 tokens, LX_OK.

The umbrella driver `tlx_run_all` matches the
`tsf_run_all` / `tsm_run_all` / `trm_run_all` / `tcn_run_all` /
`taf_run_all` shape so the future boot-time smoke harness invokes
all six drivers in one loop with a uniform return-code contract.

## 2c. `Parser` module (src/parser.pdx) — ENH-003 (#30)

### 2c.1 Purpose

The missing pipeline-level split. At `v1.0.0` (and through ENH-002)
`Pipeline::pipeline_plan` (`src/pipeline.pdx:236`) took a pre-counted
integer `stages_count`, and `CommandRecord::command_record_begin`
(`src/command_record.pdx`) took per-stage null-separated argv text —
both were written to be FED but nobody wrote the feeder. ENH-002
landed the byte-level split (Lexer); ENH-003 lands the pipeline-level
split. Every downstream consumer (builtin dispatch at ENH-004, real
exec at ENH-005, REPL at ENH-006) will consume this parser's output.

### 2c.2 Contract

```
parser_parse(input_ptr: u64, input_len: u64) -> u64
parser_reset() -> ()
```

Given the token stream a prior `lexer_tokenize` populated in
`_lx_tokens` / `_lx_token_count` on the SAME input buffer, the parser
resolves each `TOK_WORD`'s bytes (via `input_ptr + tok.offset`) into a
contiguous argv byte pool, and emits a per-stage record table.

### 2c.3 Output shape

- `_pr_stages : [u64; 24]` — 8 stages × 3 qwords each (byte offset
  `i*24` = stage `i`). Layout per stage: qword0 = argv_offset (byte
  offset into `_pr_argv_pool`), qword1 = argv_bytes (total pool
  bytes for this stage INCLUDING the NUL separators and the trailing
  NUL after the last word), qword2 = argc (number of words).
- `_pr_stage_count : u64` — number of stages populated on success
  (0..`PR_MAX_STAGES`). Written only on the `PR_OK` path; on any
  error the slot is left untouched (return code is the authoritative
  signal). Mirrors `_lx_token_count`'s discipline.
- `_pr_argv_pool : [u8; 4096]` — the contiguous byte pool. Each
  stage's `argv_ptr` for `command_record_begin` is
  `_pr_argv_pool + stage.argv_offset`; the corresponding
  `argv_bytes` is `stage.argv_bytes`.

A 3-word stage `ls -la /tmp` becomes `ls\0-la\0/tmp\0` in the pool
(12 bytes, argc=3, argv_bytes=12).

### 2c.4 Downstream contract

The output is designed against the input signatures the two existing
encoders already expose:

- `_pr_stage_count` → `Pipeline::pipeline_plan`'s `stages_count`.
  `PR_MAX_STAGES = PL_MAX_STAGES = 8` so a valid parser output is
  always handable to `pipeline_plan` without a second gate.
- `_pr_argv_pool + stage.argv_offset` →
  `CommandRecord::command_record_begin`'s `argv_ptr`.
- `stage.argv_bytes` →
  `CommandRecord::command_record_begin`'s `argv_bytes`.

The `tpr_case_golden_feed` test in `tests/test_parser.pdx` wires the
parser output into `pipeline_plan` for the `ls | cat` 2-stage line
and asserts the resulting 4 qwords byte-match the existing
`tsm_case_pipeline` golden — the load-bearing check that the
parser+planner integration produces the same bytes the M4 smoke
matrix pinned.

### 2c.5 Token classes handled

- `TOK_WORD` (kind=1) and `TOK_PIPE` (kind=2) are handled directly.
- `TOK_REDIR_IN` (3), `TOK_REDIR_OUT` (4), `TOK_SEMI` (5), and
  `TOK_AMP` (6) are silently skipped at ENH-003. Redirection
  semantics land with ENH-004/ENH-005; semicolon/ampersand with the
  REPL work in ENH-006. A caller running `ls > /tmp/f` today gets one
  stage with argv `ls\0/tmp/f\0` — semantically wrong for a real
  shell but out of scope for this issue.

### 2c.6 Error codes

- `PR_ERR_TOO_MANY_STAGES = 0xFFFFECD0` — more than `PR_MAX_STAGES`
  (8) pipeline stages.
- `PR_ERR_LEADING_PIPE = 0xFFFFECD1` — line starts with `|`.
- `PR_ERR_TRAILING_PIPE = 0xFFFFECD2` — line ends with `|`.
- `PR_ERR_EMPTY_STAGE = 0xFFFFECD3` — two `|` with nothing between.
- `PR_ERR_ARGV_POOL_OVERFLOW = 0xFFFFECD4` — words do not fit in
  `_pr_argv_pool` (4096 bytes).

The band `0xFFFFECDx` is the first unused sub-band above Lexer
(`0xFFFFECCx`); the Shell module mirrors these as `SH_PR_*` alongside
the existing `SH_LX_*` mirrors.

### 2c.7 Substrate deferral

None. The parser is a pure-function transformer over the Lexer's
`.bss` singletons and the caller-owned source buffer; it makes no
syscall and touches no substrate. This is what lets it land BEFORE
any of ENH-004 through ENH-006 (builtins through REPL) that will
consume its output.

### 2c.8 Fingerprint (`tests/test_parser.pdx`)

Eight cases in the `0xFFFFED6x` fail-code band cover the parser's
contract:

- `tpr_case_bare_ls` — `ls` → 1 stage, argv `ls\0`, argc=1.
- `tpr_case_pipe` — `ls | cat` → 2 stages, argv `ls\0`+`cat\0`,
  each argc=1.
- `tpr_case_pipe_flags` — `ls -la | cat` → 2 stages,
  `ls\0-la\0`+`cat\0` (argc=2, argc=1).
- `tpr_case_leading_pipe` — `|` → `PR_ERR_LEADING_PIPE`.
- `tpr_case_trailing_pipe` — `ls |` → `PR_ERR_TRAILING_PIPE`.
- `tpr_case_empty_stage` — `ls | | cat` → `PR_ERR_EMPTY_STAGE`.
- `tpr_case_too_many` — `a|b|c|d|e|f|g|h|i` (9 stages) →
  `PR_ERR_TOO_MANY_STAGES`.
- `tpr_case_golden_feed` — `ls | cat` → parser → `pipeline_plan`
  → asserts 4 qwords byte-match the existing `tsm_case_pipeline`
  golden. The LOAD-BEARING downstream-contract check.

The umbrella driver `tpr_run_all` matches the family shape so a
boot-time smoke harness invokes all seven drivers uniformly.

## 2d. `Builtins` + `Dispatch` modules — ENH-004 (#31)

### 2d.1 Purpose

The missing in-process command layer. At `v1.0.0` (and through
ENH-003) NO `builtin` symbol existed in `src/`, `caps.decl`, or
`design/architecture.md`. ENH-004 introduces the concept and lands
the four minimum-viable handlers the enhancement plan enumerates:
`cd`, `exit`, `export`, `pwd`. The dispatch surface
(`dispatch_line` + the runtime-loaded triple table) lives in
`src/dispatch.pdx`; the handler bodies + the shell-local env storage
live in `src/builtins.pdx`.

### 2d.2 Contract

```
Builtins:
  bi_cd     : (u64 argv_ptr, u64 argc) -> u64
  bi_exit   : (u64 argv_ptr, u64 argc) -> u64
  bi_export : (u64 argv_ptr, u64 argc) -> u64
  bi_pwd    : (u64 argv_ptr, u64 argc) -> u64
  bi_env_reset : () -> ()

Dispatch:
  dispatch_init : () -> ()
  dispatch_line : (u64 argv_ptr, u64 argc) -> u64
```

`argv_ptr` points at a stage's NUL-separated argv byte slice
(typically `_pr_argv_pool + stage.argv_offset` from ENH-003, but
dispatch is decoupled from Parser's `_pr_stages` shape -- any
NUL-separated argv layout works). Each `argv[i]` is resolved by
scanning `i` NULs forward from the base pointer.

### 2d.3 Design tension: `export` vs D5 ambient authority

`design/enhancement-plan.md` §Stage 2 flagged the tension: README /
this doc D5 state the shell reads NO environment variables and
treats env as an ambient-authority channel the project avoids. An
`export` builtin appears in direct conflict.

**ENH-004 chooses Option A per the issue's recommendation:** scope
`export` to a **shell-local variable table that is NOT inherited by
children**. D5 stands. No amendment to D5. No change to `caps.decl`.
No envp change to the `sys_execve` path. The exported table serves
the shell's own subsequent line evaluations (variable expansion at
ENH-006's REPL) -- children see nothing new.

This matches the D2/D5 stance the project has held since the v1.0.0
encoder body: capabilities are the ONLY inheritable authority. A
future need for "genuine" env inheritance would land as a distinct
KIND (e.g., `KIND_ENV_SLOT`) with explicit narrowing, not by
widening ambient env.

### 2d.4 Shell-local env storage

```
_bi_env           : [u64; 128] uninit @align(16)  -- 32 records * 4 qw each
_bi_env_count     : u64                           -- populated records
_bi_env_pool      : [u8; 4096] uninit @align(16)  -- NUL-separated backing
_bi_env_pool_used : u64                           -- bytes consumed (write ptr)
```

Record layout per issue directive (record `i` at byte offset `i*32`):

```
[i*32 +  0]  name_ptr   (into _bi_env_pool)
[i*32 +  8]  name_len
[i*32 + 16]  value_ptr  (into _bi_env_pool)
[i*32 + 24]  value_len
```

Written only on the `BI_OK` path; on any error the record slot is
left untouched (return code is the authoritative signal).
`bi_env_reset` (called from `dispatch_init` at startup) clears
`_bi_env_count` and `_bi_env_pool_used` -- record bytes past those
counts are unobservable.

### 2d.5 Dispatch table

The runtime-loaded triple table lives in `Dispatch`:

```
_bi_names      : [u64; 16] uninit @align(8)  -- pointer to NUL-terminated name
_bi_name_lens  : [u64; 16] uninit @align(8)  -- precomputed name length (excl NUL)
_bi_handlers   : [u64; 16] uninit @align(8)  -- function pointer (u64, u64) -> u64
_bi_count      : u64                          -- populated slots (== 4 at ENH-004)
```

Same three-parallel-arrays shape the monorepo's canonical dispatch
uses at `src/user/dispatch.pdx:71-74`. Adds a `_bi_name_lens` variant
so `dispatch_line` avoids a per-lookup `strlen` scan (the argv[0]
length is computed once via the byte walker, then compared against
each candidate's precomputed length). `BI_TABLE_MAX = 16` leaves 12
slots of headroom above the four ENH-004 builtins for ENH-005+
additions (help/env/echo/history/type/which/alias/jobs/read/wait/
unalias/clear) without a re-layout.

Names are short byte-array constants (`bi_name_cd` = `"cd\0"`,
etc.) in `Dispatch` module-scope. Populated at startup by
`dispatch_init` (LEA loads into the runtime table) because
paideia-as does not support address-of-symbol in static array
initializers -- same reason monorepo's `dispatch_init` at
`src/user/dispatch.pdx:104` uses this idiom.

### 2d.6 `dispatch_line` algorithm

```
if argc == 0: return BI_MISS
argv0_len = walker_strlen(argv_ptr)
for i in 0.._bi_count:
  if _bi_name_lens[i] != argv0_len: continue        (fast length gate)
  if bytes(argv_ptr, _bi_names[i], argv0_len) match:
    return _bi_handlers[i](argv_ptr, argc)
return BI_MISS
```

Byte compare is inline (no `memcmp` dependency). The four ENH-004
names have four distinct lengths (2/4/6/3), so length alone
disambiguates all four candidates -- byte compare is only reached
for the matching candidate.

### 2d.7 Error codes

Fresh sub-band `0xFFFFECEx`:

- `BI_MISS = 0xFFFFECE0` -- dispatch found no matching builtin.
  This is the REPL's signal to try the external command path
  (ENH-005), not an error.
- `BI_ERR_CD_NO_ARG = 0xFFFFECE1` -- `cd` invoked without a path.
  Distinct from `BI_ERR_CD_FAIL` per issue -- the user's fix is
  different (type a path vs fix the path).
- `BI_ERR_CD_FAIL = 0xFFFFECE2` -- `sys_chdir` returned negative
  errno.
- `BI_ERR_EXIT_BAD_CODE = 0xFFFFECE3` -- `exit` argv[1] does not
  start with a decimal digit.
- `BI_ERR_EXPORT_MALFORMED = 0xFFFFECE4` -- `export` argv[1] has
  no `=` or the name (bytes before `=`) is empty.
- `BI_ERR_EXPORT_TABLE_FULL = 0xFFFFECE5` -- `_bi_env_count ==
  BI_ENV_TABLE_MAX`.
- `BI_ERR_EXPORT_POOL_FULL = 0xFFFFECE6` -- name + value bytes
  would exceed `BI_ENV_POOL_SIZE` (4096).
- `BI_ERR_PWD_TOO_LONG = 0xFFFFECE7` -- `sys_getcwd` returned
  negative errno.

The Shell module mirrors these as `SH_BI_*` alongside the existing
`SH_LX_*` / `SH_PR_*` mirrors.

### 2d.8 Substrate deferral

`bi_cd`, `bi_exit`, `bi_pwd` call the real kernel syscall wrappers
from `Syscall` (`sys_chdir` SC+ 85, `sys_exit` SC+ 60, `sys_getcwd`
SC+ 86, `sys_write` SC+ 1). These wrappers were landed at ENH-001;
the paideia-os kernel bodies for `sys_chdir` / `sys_getcwd` landed
at R86.M1-006/007 (paideia-os #1959/#1960). No substrate deferral
for the syscall floor.

The `sys_chdir` + `sys_getcwd` round-trip (`cd /tmp` followed by
`pwd` prints `/tmp`) is a live-kernel property verified by the
paideia-os side's boot-time smoke harness (parallel to the
substrate-half smoke for `tsm_run_all` / `tsf_run_all`). The
pure-function properties of the dispatch + argv-parse layer are
tested here in `tests/test_builtins.pdx` and covered under the
0xFFFFED7x fail-code band.

### 2d.9 Fingerprint (`tests/test_builtins.pdx`)

Six cases in the `0xFFFFED7x` fail-code band cover the pure-function
surface:

- `tbi_case_dispatch_miss_ls` -- argv `ls\0` -> `BI_MISS`.
- `tbi_case_dispatch_hit_export` -- argv `export\0FOO=bar\0` ->
  `BI_OK`, `_bi_env_count == 1`, record `[0]` has `name_len=3`,
  `value_len=3`. Load-bearing end-to-end case.
- `tbi_case_cd_no_arg` -- `bi_cd(argc=1)` -> `BI_ERR_CD_NO_ARG`
  (rejects before touching `sys_chdir`).
- `tbi_case_export_shell_local` -- `bi_export("X=y")` -> `BI_OK`,
  verifies record layout AND pool bytes (`X\0y\0`) byte-for-byte.
- `tbi_case_export_malformed` -- `bi_export("FOO")` ->
  `BI_ERR_EXPORT_MALFORMED`, verifies `_bi_env_count` still 0
  (reject leaves state untouched).
- `tbi_case_dispatch_hit_pwd` -- `dispatch_line("pwd", 1)` ->
  any non-`BI_MISS` (either `BI_OK` on live kernel or
  `BI_ERR_PWD_TOO_LONG` offline). Verifies dispatch reached
  `bi_pwd`; the sys_getcwd round-trip is deferred to live boot.

The umbrella driver `tbi_run_all` matches the family shape so a
boot-time smoke harness invokes all eight drivers uniformly.

## 3. `LineReader` module (src/line_reader.pdx)

### 3.1 Contract

```
line_reader_read_line(buf: u64, buf_len: u64) -> u64
lr_read_one_byte(byte_ptr: u64) -> u64
```

`line_reader_read_line` reads one line from fd 0 (stdin) into `buf`,
one byte at a time. Return matrix (ENH-007, #34):

- Successful line (newline seen): bytes-written INCLUDING the
  terminating `\n`. Matches the monorepo `shell_read_line` shape
  (`src/user/shell.pdx:29`).
- EOF at start (first read returns 0, count == 0): `LR_ERR_EOF`
  (0xFFFFEC13).
- Mid-stream EOF (0-byte read after some bytes read): bytes-written-
  so-far (this is the "Ctrl-D on non-empty line" shape).
- Buffer full without newline: bytes-written (== buf_len). No
  overflow sentinel; the caller receives a partial line and future
  line-continuation polish (ENH-011 / R66) can glue pieces without
  an error round-trip.
- Unrecoverable read error (negative errno from `sys_read`):
  `LR_ERR_READ_FAIL` (0xFFFFEC14).
- `buf == 0 || buf_len == 0`: `LR_ERR_BAD_BUF` (0xFFFFEC11).

`lr_read_one_byte` is the SINGLE SEAM between the LineReader and the
byte transport; see §3.3.

### 3.2 ENH-007 implementation

The M1 body returned `LR_STUB = 0xFFFFEC10` on the happy path because
no `syscall` instruction existed anywhere in the shell tree (that
absence tracked at ENH-001 / #28). ENH-001 landed the syscall floor
and ENH-007 (#34) retires `LR_STUB`: `line_reader_read_line` now
issues real reads.

Register plan (3 callee-save pushes, rsp%16==0 at every nested call):
- `r12` — current buffer pointer (advances one byte per read)
- `r13` — `buf_len` (invariant)
- `r14` — bytes-read count (drives buffer-full check and return value)

Loop shape (matches the monorepo `shell_read_line` at
`src/user/shell.pdx:29`):

```
push r12; push r13; push r14
r12 = buf; r13 = buf_len; r14 = 0
shell_note(SH_ST_PROMPTS)
gate: buf non-null; buf_len non-zero  → else LR_ERR_BAD_BUF
loop:
    if r14 >= r13:  → return count (buffer full)
    lr_read_one_byte(r12)
    if rax == 0:    → EOF (LR_ERR_EOF if count==0 else return count)
    if signed(rax) < 0: → LR_ERR_READ_FAIL
    // rax == 1: one byte was written to [r12]
    peek [r12] via xor+mov_b
    r14++; r12++
    if byte == 0x0A: → return count (includes newline)
    jmp loop
```

Counter discipline (see `_shell_stats` layout in §5): `SH_ST_PROMPTS`
bumps on every entry, `SH_ST_LINES` on every bytes-written return,
`SH_ST_ERRORS` on every error sentinel. The invariant
`PROMPTS - LINES - ERRORS == 0` holds across a full session; a
divergence is a live-counter regression.

### 3.3 Cap-typed `KIND_TTY(read)` deferral

The read syscall lives in exactly one helper — `lr_read_one_byte` —
so the transport can be swapped at ONE site without touching the
read loop or any future line-editing polish (raw mode, backspace,
cursor moves, history recall — tracked at ENH-011 / #38 as R66 shell
polish tier 1).

Today the seam calls `sys_read(0, byte_ptr, 1)` — the VFS-mediated
fd-0 path the paideia-os monorepo's own shell has used since
R17.M3-002 (#622). The cap-typed alternative — a `KIND_TTY(read)`
invoke that would let userspace bypass the VFS layer and negotiate
raw / cooked mode explicitly — requires kernel work already tracked
at paideia-os#1986 (add `KIND_TTY_OP_READ` op alongside the extant
921-line `src/kernel/core/cap/kind_tty.pdx`). We deliberately do NOT
block ENH-007 on #1986:

- The stub's original justification cited "KIND_TTY has not landed
  in the paideia-os kernel at HEAD (2026-08-21)", but 921 lines of
  `kind_tty.pdx` exist today; only the read op is missing.
- The fd-0 fallback works TODAY and is the exact pattern the monorepo
  shell uses. Blocking the shell's ability to read a line on a
  kernel-side improvement would leave the REPL loop non-functional
  for the entire time #1986 sits open.
- The single-seam design means the migration is a ONE-SITE change
  inside `lr_read_one_byte` when #1986 lands: swap the `sys_read`
  call for a `cap_invoke(tty_cap, TTY_OP_READ, byte_ptr, 1)`. Every
  caller in the loop and every future line-editor polish sits behind
  the seam untouched.

Future line-editing polish (ENH-011 / #38, tracking issues #17-#21
under R66 shell polish tier 1: raw mode, backspace erase, history
ring recall, cursor movement) reads through this same seam. Those
issues become startable only after ENH-007 lands, since the byte
loop they extend did not exist until this change.

## 3a. `Session` module (src/session.pdx) — M2-001

### 3a.1 Contract

```
session_mint(dst: u64, slot: u64, session_id: u64) -> u64
session_derive_subcap(dst: u64, slot: u64, parent_session_id: u64) -> u64
```

Both entry points write a 16-byte `KIND_SHELL_SESSION` Cap record into
the caller-owned `dst` buffer using the same wire layout every Cap in
the ecosystem shares (matches libpdx-cap's `Cap` format at
`src/cap.pdx`). `session_mint` writes with `SS_RIGHTS_ALL` (read | write
| mint) — the shell's own root session Cap. `session_derive_subcap`
writes with `SS_RIGHTS_CHILD` (read | write only, no mint) — a child's
session Cap, strict-monotone-narrowed at the constant level.

### 3a.2 Rights masks

- `SS_RIGHTS_READ = 0x1` — session-scope reads.
- `SS_RIGHTS_WRITE = 0x2` — session-scope writes (audit-log join).
- `SS_RIGHTS_MINT = 0x4` — authority to derive further sub-caps.
- `SS_RIGHTS_ALL = 0x7` — parent (this shell).
- `SS_RIGHTS_CHILD = 0x3` — child (read + write only).

### 3a.3 Error codes

`SS_ERR_BAD_DST` (0xFFFFEC30), `SS_ERR_BAD_ID` (0xFFFFEC31), and
`SS_ERR_BAD_SLOT` (0xFFFFEC32) — all three are fail-fast before any
store to `dst`, matching libpdx-cap `cap_pack`'s "reject leaves the
caller's buffer untouched" discipline.

### 3a.4 Interaction with the InitCap sidecar

The 16-byte wire record produced by these helpers is one entry in the
child's InitCap sidecar (paideia-os `src/kernel/core/loader/
init_caps.pdx`, R20b.M4-001). At M2-002 the pipeline planner emits one
`session_derive_subcap` request per child stage; the returned bytes
land contiguously in the child's sidecar buffer alongside the pipe
endpoint Caps and the per-tool caps.decl requirements.

## 3b. `Pipeline` module (src/pipeline.pdx) — M2-002

### 3b.1 Contract

```
pipeline_plan(dst: u64, stages_count: u64, dst_max_entries: u64,
              first_slot: u64) -> u64
pipeline_reset() -> ()
```

Given a pipeline of N stages (`a | b | c` has N = 3, two `|`
operators, and requires N-1 = 2 pipe endpoints), `pipeline_plan`
writes `2*(N-1)` 16-byte Cap wire records into the caller-owned
`dst` buffer. For each pipe p in `0..N-1`:

- `dst[2p+0]` — upstream stage's stdout: KIND=5 (KIND_IPC_ENDPOINT),
  rights=WRITE, target_ptr=p (placeholder pipe id).
- `dst[2p+1]` — downstream stage's stdin: KIND=5, rights=READ,
  target_ptr=p.

The number of entries written is placed in the singleton
`pipeline_entries_written` (`.bss`, 8-byte aligned) so the caller can
advance its sidecar cursor without recomputing the formula.

### 3b.2 Sidecar layout

A 3-stage pipeline `a | b | c` produces 4 entries; a 4-stage pipeline
produces 6. Pattern: `2 * (stages_count - 1)`. Bare command
(`stages_count == 1`) produces 0 entries — valid pipeline of length 1.

### 3b.3 Substrate deferral

At M2 the `target_ptr` field carries a placeholder pipe id (`0, 1, 2,
...`). The M3+ substrate wiring replaces these with real endpoint ids
returned by `sys_ipc_recv`. This is the same "structure first, kernel-
side wiring later" discipline libpdx-cap M2 followed for
`cap_manifest_verify` — the layout is fully determined at M2, only
the byte value in one field changes.

### 3b.4 Error codes

- `PL_ERR_BAD_ARGS` (0xFFFFEC40) — `dst == 0` or `stages_count == 0`.
- `PL_ERR_TOO_MANY` (0xFFFFEC41) — `stages_count > PL_MAX_STAGES (8)`.
- `PL_ERR_DST_OVERFLOW` (0xFFFFEC42) — dst too small for
  `2*(stages_count-1)` entries.

All three are fail-fast — `dst` is not touched on any reject path.

## 4. `Exec` module (src/exec.pdx)

### 4.1 Contract

```
exec_spawn_and_wait(argv_pool_ptr: u64,      // NUL-separated argv text (parser output slice)
                    argv_bytes: u64,          // total bytes in the slice
                    argc: u64) -> u64         // word count in the slice
```

- Marshal the parser's per-stage NUL-separated argv pool into the
  child's `char**` argv array.
- Open a `ShellCommandRecord` (audit-first, durable BEFORE the child
  runs; D3 invariant).
- Spawn a child from `argv[0]` via `sys_execve`.
- Block on `sys_wait4`, extract exit code from `wstatus` low byte.
- Close the audit record with the exit code (or 127 on
  execve/wait failure so the record never leaks OPEN).
- Returns the child's exit code (0..255) on the substrate-live path,
  or an `EX_ERR_*` code (0xFFFFEC2x band) on error.

**ENH-005 signature note:** the v1.0.0 M1 contract took `(argv,
argv_count)` where `argv` was already a `char**` array; ENH-005 makes
the marshalling a step of the body (taking the parser's pool slice
directly) since no caller ever consumed the M1 shape (verified via
grep at ENH-005 landing time).

### 4.2 M1 skeleton (superseded by ENH-005 M2 body)

M1 gated `argv != 0 && argv_count != 0` and returned `EX_STUB`
(0xFFFFEC20) on the happy path — the "we validated the args, we would
call sys_execve if we had a userspace sys_execve wrapper linked, but
we don't yet" signal. **Retired at ENH-005** (see §4.3). The
`EX_STUB` constant is retained in `src/shell.pdx` at its original
value for external decoder compatibility; the shell body no longer
returns it.

### 4.2b `exec_narrow_child_caps` — M2-003

```
exec_narrow_child_caps(parent: u64, parent_count: u64,
                       child_decl: u64, child_decl_count: u64,
                       dst: u64, dst_max_entries: u64) -> u64
```

Pure cap-narrowing helper: no substrate touch, no syscall. For each
entry in the child's caps.decl (wire-form), the function:

1. Linearly scans `parent` for the matching KIND.
2. Refuses if no match: `EX_ERR_MISSING_CAP` (0xFFFFEC24).
3. Refuses if the child requests rights the parent does not hold —
   the widen check `(child & ~parent) == 0`, same as libpdx-cap
   `cap_pack_narrowed`: `EX_ERR_WIDENING` (0xFFFFEC25).
4. Writes a narrowed Cap to `dst[i]` with:
   - `slot` = child's requested slot (from decl).
   - `kind` = child's requested kind (== parent's kind by scan).
   - `rights` = `child & parent` (intersection).
   - `target_ptr` = parent's `target_ptr` (the child cap points at
     the parent's target, not at a decl-invented target).

The output is a flat 16-byte-per-entry array the exec layer
concatenates with the session-cap entry (from `session_derive_subcap`,
M2-001) and the pipe-endpoint entries (from `pipeline_plan`, M2-002)
into one per-child InitCap sidecar at `sys_execve` time.

`EX_ERR_SIDECAR_FULL` (0xFFFFEC26) — `dst_max_entries <
child_decl_count`.

The `EX_STUB` skeleton in `exec_spawn_and_wait` is unchanged at
M2-003 — the sys_execve call remains a substrate deferral. This
helper is invoked separately by the shell's exec dispatcher once the
substrate lands; every path that reaches `sys_execve` in M3+ will
first pass through `exec_narrow_child_caps`.

### 4.3 M2 evolution (LIVE after ENH-005)

`exec_spawn_and_wait` executes this ordered 7-step sequence — the
ordering itself is the load-bearing property. A reader walking the
body top-to-bottom sees each step in the same order as this doc.

0. **Build child argv[]** via `exec_build_argv_ptrs` from the
   parser's NUL-separated pool slice into `_ex_argv_ptrs`. The
   NULL sentinel at `_ex_argv_ptrs[argc]` matches the frozen
   ABI at `design/user/execve-abi.md` (`argv[argc] == NULL`).
1. **Resolve path** = `_ex_argv_ptrs[0]`. Full PATH search over
   the InitCap-seeded PATH cap set is deferred to ENH-006 (REPL);
   ENH-005 lands the exact-argv[0] path.
2. **Narrow the child's caps** via `exec_narrow_child_caps`
   (unchanged since M2-003). ENH-005 uses a placeholder parent
   cap (`SH_KIND_SHELL_SESSION` with `RIGHTS_ALL`, `target_ptr=0`)
   and `child_decl_count=0` (trivially succeeds). Replace with the
   real ambient cap set + parsed `caps.decl` once runtime cap-table
   introspection and libpdx-cap's `caps_decl` parser land.
3. **cap_manifest_verify** — DEFERRED at ENH-005 (libpdx-cap not
   linked in the shell repo). Step 2 carries the load-bearing
   widening/narrowing invariants today.
4. **`command_record_begin`** into `_ex_audit_rec` BEFORE
   `sys_execve`. This is where D3's audit-first invariant becomes
   a call-graph property of the shell, not just an encoder property
   (`test_audit_first.pdx` covers the encoder half;
   `test_exec.pdx`'s `tex_case_sw_audit_first` extends it to the
   live path). Failure at this gate returns
   `EX_ERR_AUDIT_BEGIN_FAIL` **without proceeding to exec** — the
   child never runs if the audit record cannot be opened.
   `audit_id` is a placeholder (`1`); `ts_begin_ns` is `0`. Both
   wire to libpdx-audit / `sys_clock_monotonic` when those
   substrates land.
5. **`sys_execve(path, _ex_argv_ptrs, envp=NULL)`**. `envp=NULL`
   per D5 (no env-var leak to children). On success, `sys_execve`
   never returns (kernel replaces the shell image). On failure,
   returns a negative errno; the audit record is closed with
   exit=127 before `EX_ERR_EXECVE_FAIL` is returned.
6. **`sys_wait4(pid=-1, &_ex_wstatus, 0, 0)`**. Reaps the child;
   `wstatus` low byte is the exit code per the M2 doc. Under the
   current syscall floor (no `sys_fork`; see §4.3.FORK GAP below)
   this call is structurally reachable only if `sys_execve`
   returned failure, at which point `sys_wait4` will typically also
   fail (`-ECHILD`); kept per the M2 CALL GRAPH ordering so a
   future `sys_fork` insertion is a one-line change.
7. **`command_record_close(exit_code)`**. CLOSED flag set;
   HAS_ERROR set iff `exit_code != 0`. On any failure above, close
   with `exit=127` so the audit journal never carries an orphaned
   OPEN record.

#### 4.3.FORK GAP

A correct fork+execve+wait pattern requires `sys_fork` (SC+ 56),
which the ENH-001 Syscall floor deliberately did not expose (the
enhancement-plan §4 Stage 0 enumeration lists only the 9 sysnos the
shell v2.0 plan consumes; fork was not enumerated). ENH-005 lands
the ordered sequence as the doc specifies; runtime semantics under
the current syscall floor: `sys_execve` either succeeds (never
returns; shell becomes child) or fails (returns errno; audit close +
`EX_ERR_EXECVE_FAIL`). `sys_wait4` is only reached if `sys_execve`
returned failure. A future ENH that adds `sys_fork` makes `sys_wait4`
meaningful without touching the ordered sequence in the body.

The D3 property (audit-first, durable-before-child) is fully
enforced today: `command_record_begin` runs BEFORE `sys_execve`, and
no reject path skips it. That is the invariant the test suite
falsifies.

#### 4.3 pipeline

The pipeline shape (`a | b | c`), minting one `KIND_IPC_ENDPOINT`
per `|` and splicing it into the paired children's stdin/stdout via
a second InitCap sidecar entry, is scaffolded at M2-002
(`pipeline_plan`) and lands as a live shape when the REPL (ENH-006)
drives per-stage `exec_spawn_and_wait` calls with the parser's
`_pr_stages[i]` records in sequence.

## 4a. `Pds` module (src/pds.pdx) — M2-004

### 4a.1 Contract

```
pds_parse(buf: u64, buf_len: u64) -> u64
pds_reset() -> ()
```

Parses the HEADER of a `.pds` script (per `design/terminal/pds-format.md`).
The header is a run of lines each starting with `#!` (shebang, first
line only) or `#<pragma>`. First non-`#` line or blank line ends the
header.

Populates the `.bss` singleton `PdsHeader` record:

- `pds_has_shebang` — 1 if a shebang was seen, else 0.
- `pds_ascii_flag` — 1 if `#ascii` was seen, else 0.
- `pds_capability_count` — number of `#capability` pragmas (≤ 16).
- `pds_import_count` — number of `#import` pragmas (≤ 8).
- `pds_schema_count` — number of `#schema` pragmas (≤ 8).
- `pds_body_offset` — byte offset of the first body byte in `buf`.

### 4a.2 Dispatch

Second-byte lookahead is enough to disambiguate the M2 pragma set:
`!`→shebang, `c`→capability, `i`→import, `s`→schema,
`r`→requires-paideia (no-op recorded), `a`→ascii. Any other second
byte is `PDS_ERR_MALFORMED` (0xFFFFEC51). Overflow of any of the
three counts returns `PDS_ERR_OVERFLOW` (0xFFFFEC52).

### 4a.3 Body dispatch

The body is shell pipeline syntax; the parser does NOT re-parse it.
Body execution goes through the same `pipeline_plan` + `exec_narrow_
child_caps` machinery M2-002 and M2-003 landed. `pds_body_offset`
tells the caller where the body starts; the caller reads bytes from
there through the normal shell line-reader path.

### 4a.4 String values not materialised

The parser tracks COUNTS + FLAGS only. Pragma STRING VALUES (the
capability names, import paths, schema paths) are re-read by the
consumer at exec time when needed. If M3 requires them, extend the
singleton with `(offset, length)` pairs — mirrors libpdx-argv's
flag_names discipline.

## 4b. `History` module (src/history.pdx) — M2-005

### 4b.1 Contract

```
history_encode_record(dst: u64, dst_len: u64,
                      cmd_ptr: u64, cmd_len: u64,
                      ts_ns: u64, flags: u64) -> u64
history_reset() -> ()
```

Pure byte-serialiser: writes one `HistoryEntry` record into the
caller-owned `dst` buffer. Number of bytes written is placed in the
`.bss` singleton `history_bytes_written` (8-byte aligned) so the
caller can advance its journal cursor without recomputing padding.

### 4b.2 Wire format

Fixed 24-byte header + variable command bytes + 0..7 zero pad:

```
+0    u32 magic         = 0x54534948 ("HIST" bytes 'H','I','S','T')
+4    u32 record_len    total bytes; always an 8-multiple
+8    u64 ts_ns         wall-clock nanoseconds (caller-supplied)
+16   u32 cmd_len       command length
+20   u32 flags         bit 0 HAS_ERROR, bit 1 SCRIPT, rest reserved
+24   u8[cmd_len]       UTF-8 command text
+...  0..7 zero bytes   padding to align record_len to 8
```

Each of the three header qwords is a single MOV — a torn write
between fields inside one record is impossible on x86-64. `record_len`
is computed as `(24 + cmd_len + 7) / 8 * 8` via shr/shl (no large-imm
mask).

### 4b.3 Error codes

- `HIST_ERR_BAD_ARGS` (0xFFFFEC60) — `dst == 0`, `dst_len == 0`, or
  `cmd_ptr == 0 && cmd_len > 0`. `cmd_len == 0` is allowed (records
  the "empty enter" event).
- `HIST_ERR_TOO_LONG` (0xFFFFEC61) — `cmd_len > 4096`
  (`HIST_CMD_MAX`).
- `HIST_ERR_TRUNCATED` (0xFFFFEC62) — `dst_len` less than required.

All three are fail-fast — `dst` is not touched on reject.

### 4b.4 Substrate deferral (PdxFS write)

The M2 module builds the wire bytes; the M3+ substrate wiring appends
them to `~/.history/<session>-<ts>.pdxhist` via
`sys_ipc_send(svc.pdxfs-journal, encoded_bytes)`. PdxFS v1 has landed
`KIND_PDXFS_FILE` at HEAD (paideia-os R42 scaffold, commits `411ad0e`
/ `2ff76d4`), but the userspace-write path is not wired in the shell
repo at HEAD. Same discipline as `LineReader` / `Exec`: build the
pure logic at M2, defer the substrate boundary to M3+.

### 4b.5 caps.decl amendment

`caps.decl` gains `KIND_PDXFS_FILE(write)` at M2-005. The shell
narrows this cap per-session to the invoker's own history subtree
via libpdx-cap's `cap_pack_narrowed` at session start; children
never receive this cap (history subtree is the shell's own state).

## 4c. `PipePassthrough` module (src/pipe_passthrough.pdx) — M3-001

### 4c.1 Contract

```
pipe_passthrough_forward(src: u64, src_len: u64,
                         dst: u64, dst_max: u64) -> u64
pipe_passthrough_reset() -> ()
```

Given one R20b frame in `src` (8-byte header + `payload_len` bytes
of payload — schema_hash prefix + record body included if the
child set the R20b "typed" flag), copy it verbatim to `dst`. The
number of bytes forwarded (always `8 + payload_len` on success)
lands in the `.bss` singleton `passthrough_bytes_forwarded` so
both endpoint cursors advance by the same amount.

### 4c.2 Passthrough discipline

The shell does NOT decode the schema, does NOT re-hash the
schema_hash prefix, and does NOT touch any byte of the payload.
This is D2 literal from `design/tooling/plan.md`: the shell
forwards typed pipes; it does not schema-erase them into byte
streams the downstream cannot re-type. The module deliberately does
NOT link libpdx-semantic-pipe — the passthrough must be correct
against a schema the shell has never seen, so a child at R56+ that
ships a new schema needs no shell rebuild to be pipeable to.

### 4c.3 R20b frame header

Mirror of paideia-os `src/kernel/core/ipc/frame.pdx`:

```
+0  u8   op           opcode (SEND=1, RECV=2, ...; preserved as-is)
+1  u8   ver          version (currently 1)
+2  u16  flags LE     bit 0 = typed record follows
+4  u32  payload_len  bytes of payload after the header
```

The 8 bytes are loaded as one aligned qword; `payload_len` is
extracted from bits 32..63 via `shr rax, 32`.

### 4c.4 Error codes

- `PP_ERR_BAD_ARGS` (0xFFFFEC70) — `src == 0`, `dst == 0`,
  `dst_max == 0`, or `src_len < 8`.
- `PP_ERR_TRUNCATED` (0xFFFFEC71) — `src_len < 8 + payload_len`
  (source buffer does not contain the whole frame).
- `PP_ERR_DST_OVERFLOW` (0xFFFFEC72) — `dst_max < 8 + payload_len`.
- `PP_ERR_OVERSIZED` (0xFFFFEC73) — `payload_len > PP_MAX_PAYLOAD`
  (0x7FFFFFF7). Malformed frame on the wire.

All four are fail-fast — `dst` is not touched on any reject path.

## 4d. `Completion` module (src/completion.pdx) — M3-002

### 4d.1 Contract

```
completion_encode_record(dst: u64, dst_len: u64,
                         name_ptr: u64, name_len: u64,
                         kind: u64, score: u64) -> u64
completion_reset() -> ()
```

Serialise one `CommandCompletion` record (per SH-D7 in
`design/terminal/semantic-shell.md`) into a caller-owned buffer.
The byte count lands in the `.bss` singleton
`completion_bytes_written`.

### 4d.2 Wire format

Fixed 16-byte header + variable name bytes + 0..7 zero pad:

```
+0    u32 magic         = 0x504d4f43 ("COMP" LE)
+4    u32 record_len    total bytes; always an 8-multiple
+8    u16 kind          COMP_KIND_* (1..5)
+10   u16 score         match score 0..1000
+12   u32 name_len      candidate byte length
+16   u8[name_len]      UTF-8 candidate name (not null-terminated)
+...  0..7 zero bytes   padding to align record_len to 8
```

Each header qword is a single MOV — atomic against a reader
observing the same qword.

### 4d.3 Kind vocabulary

- `COMP_KIND_COMMAND = 1` — installed tool.
- `COMP_KIND_FILE    = 2` — file candidate.
- `COMP_KIND_DIR     = 3` — directory candidate.
- `COMP_KIND_OPTION  = 4` — `--long` / `--json` etc.
- `COMP_KIND_SCHEMA  = 5` — schema-typed field.

Closed at M3; extending is a schema-version bump. Reserved values
0 and 6..65535 fall back to plain-text rendering.

### 4d.4 Error codes

- `COMP_ERR_BAD_ARGS` (0xFFFFEC80) — `dst == 0`, `dst_len == 0`,
  `name_ptr == 0`, `kind == 0`, `kind > COMP_KIND_MAX`, or
  `score > COMP_SCORE_MAX`.
- `COMP_ERR_TOO_LONG` (0xFFFFEC81) — `name_len > COMP_NAME_MAX`
  (512).
- `COMP_ERR_TRUNCATED` (0xFFFFEC82) — `dst_len` less than required.
- `COMP_ERR_EMPTY_NAME` (0xFFFFEC83) — `name_len == 0`. Distinct
  from BAD_ARGS so a caller-side ranker bug is diagnosable.

All four are fail-fast — `dst` is not touched on any reject path.

## 4e. `CommandRecord` module (src/command_record.pdx) — M3-003

### 4e.1 Contract

```
command_record_begin(dst: u64, dst_len: u64,
                     argv_ptr: u64, argv_bytes: u64,
                     audit_id: u64, ts_begin_ns: u64) -> u64
command_record_close(dst: u64, dst_len: u64,
                     ts_end_ns: u64, exit_code: u64) -> u64
```

Two-phase encoder for the audit journal's `ShellCommandRecord`.
Per D3 audit-first, the shell's exec dispatcher:

1. Calls `command_record_begin` BEFORE `sys_execve`. Record is
   written durable; child cannot emit until the record hits the
   journal.
2. Calls `command_record_close` AFTER `sys_wait4`. Updates
   `ts_end_ns`, `exit_code` (replacing the `CMDR_EXIT_PENDING =
   0xFFFFFFFF` sentinel), and sets `CMDR_FLAG_CLOSED` (+
   `CMDR_FLAG_HAS_ERROR` if `exit_code != 0`).

### 4e.2 Wire format

Fixed 48-byte header (six qwords) + variable argv bytes (null-
separated) + 0..7 zero pad:

```
+0    u32 magic        = 0x52444d43 ("CMDR" LE)
+4    u32 record_len   total bytes; always an 8-multiple
+8    u64 audit_id     issued by libpdx-audit's audit_begin
+16   u64 ts_begin_ns  wall-clock at begin
+24   u64 ts_end_ns    wall-clock at close (0 while open)
+32   u32 argv_bytes   argv text length
+36   u32 exit_code    child status; CMDR_EXIT_PENDING while open
+40   u32 flags        bit 0 CLOSED, bit 1 HAS_ERROR
+44   u32 reserved     0
+48   u8[argv_bytes]   argv text (null-byte separated)
+...  0..7 zero bytes  padding to align record_len to 8
```

Each header qword is a single MOV. On close only two qwords change
(qword2 ts_end_ns, qword4 exit_code | argv_bytes, qword5 flags).

### 4e.3 Exit-code sentinel

`CMDR_EXIT_PENDING = 0xFFFFFFFF` marks "record open, wait has not
returned yet". A reader seeing `exit_code == 0xFFFFFFFF` and
`CLOSED` unset knows the child is still running or the record was
truncated (shell crashed between begin and close). `0xFFFFFFFF`
cannot collide with a legal exit (wstatus low byte 0..255).

### 4e.4 Error codes

- `CMDR_ERR_BAD_ARGS` (0xFFFFEC90) — `dst == 0`, `dst_len == 0`,
  `audit_id == 0`, or `argv_ptr == 0 && argv_bytes > 0`.
- `CMDR_ERR_TOO_LONG` (0xFFFFEC91) — `argv_bytes > CMDR_ARGV_MAX`
  (8192).
- `CMDR_ERR_TRUNCATED` (0xFFFFEC92) — `dst_len < record_len`.
- `CMDR_ERR_BAD_EXIT` (0xFFFFEC93) — `close` only: `exit_code >
  255`. `CMDR_EXIT_PENDING` deliberately above the ceiling so it
  cannot be confused with a real exit.

### 4e.5 Substrate deferral (libpdx-audit)

The M3 module builds the wire bytes. The M4+ substrate wiring
calls libpdx-audit's `audit_begin`/`audit_commit` around the
begin/close encoder pair, writing the bytes to
`/system/audit/user-events/` via `sys_ipc_send(svc.audit-journal,
encoded_bytes)`. libpdx-audit has landed M2 (per STATUS.md
sibling-libraries list); the cross-repo linkage lands with M4 when
the smoke matrix pulls both sides into one build.

## 5. Return-code band `0xFFFFECxx`

```
0xFFFFEC00  SH_OK               general success sentinel (unused at M1)
0xFFFFEC10  (retired)           was LR_STUB; retired at ENH-007 (#34); value unallocated
0xFFFFEC11  LR_ERR_BAD_BUF      buf == 0 or buf_len == 0
0xFFFFEC12  LR_ERR_TTY_UNBOUND  reserved: cap-typed KIND_TTY(read) missing (paideia-os#1986)
0xFFFFEC13  LR_ERR_EOF          sys_read returned 0 with no bytes read (EOF at start)
0xFFFFEC14  LR_ERR_READ_FAIL    ENH-007: sys_read returned a negative errno
0xFFFFEC20  EX_STUB             Exec.M1: validated, no live spawn yet
0xFFFFEC21  EX_ERR_BAD_ARGV     argv == 0 or argv_count == 0
0xFFFFEC22  EX_ERR_EXECVE_FAIL  M2+: sys_execve refused the child
0xFFFFEC23  EX_ERR_WAIT_FAIL    M2+: sys_wait4 returned an unexpected code
0xFFFFEC24  EX_ERR_MISSING_CAP  M2+: child caps.decl names a KIND parent lacks
0xFFFFEC25  EX_ERR_WIDENING     M2+: child asks for rights parent does not hold
0xFFFFEC26  EX_ERR_SIDECAR_FULL M2+: sidecar dst buffer too small
0xFFFFEC30  SS_ERR_BAD_DST      Session.M2: dst == 0
0xFFFFEC31  SS_ERR_BAD_ID       Session.M2: session_id == 0
0xFFFFEC32  SS_ERR_BAD_SLOT     Session.M2: slot >= 256
0xFFFFEC40  PL_ERR_BAD_ARGS     Pipeline.M2: dst == 0 or stages == 0
0xFFFFEC41  PL_ERR_TOO_MANY     Pipeline.M2: stages > PL_MAX_STAGES
0xFFFFEC42  PL_ERR_DST_OVERFLOW Pipeline.M2: dst_max_entries insufficient
0xFFFFEC50  PDS_ERR_BAD_ARGS    Pds.M2: buf == 0 or buf_len == 0
0xFFFFEC51  PDS_ERR_MALFORMED   Pds.M2: pragma name not recognised
0xFFFFEC52  PDS_ERR_OVERFLOW    Pds.M2: too many caps/imports/schemas
0xFFFFEC60  HIST_ERR_BAD_ARGS   History.M2: dst == 0 or cmd_ptr == 0
0xFFFFEC61  HIST_ERR_TOO_LONG   History.M2: cmd_len > HIST_CMD_MAX
0xFFFFEC62  HIST_ERR_TRUNCATED  History.M2: dst_len < required
0xFFFFEC70  PP_ERR_BAD_ARGS     PipePassthrough.M3: src/dst null or src_len<8
0xFFFFEC71  PP_ERR_TRUNCATED    PipePassthrough.M3: src_len < 8+payload_len
0xFFFFEC72  PP_ERR_DST_OVERFLOW PipePassthrough.M3: dst_max < 8+payload_len
0xFFFFEC73  PP_ERR_OVERSIZED    PipePassthrough.M3: payload_len > PP_MAX_PAYLOAD
0xFFFFEC80  COMP_ERR_BAD_ARGS   Completion.M3: dst/name null, kind/score OOR
0xFFFFEC81  COMP_ERR_TOO_LONG   Completion.M3: name_len > COMP_NAME_MAX
0xFFFFEC82  COMP_ERR_TRUNCATED  Completion.M3: dst_len < required
0xFFFFEC83  COMP_ERR_EMPTY_NAME Completion.M3: name_len == 0
0xFFFFEC90  CMDR_ERR_BAD_ARGS   CommandRecord.M3: dst null or audit_id == 0
0xFFFFEC91  CMDR_ERR_TOO_LONG   CommandRecord.M3: argv_bytes > CMDR_ARGV_MAX
0xFFFFEC92  CMDR_ERR_TRUNCATED  CommandRecord.M3: dst_len < required
0xFFFFEC93  CMDR_ERR_BAD_EXIT   CommandRecord.M3: exit_code > 255 (close)
0xFFFFECC0  LX_ERR_OVERFLOW           Lexer.ENH-002: >TOK_MAX_PER_LINE tokens
0xFFFFECC1  LX_ERR_UNTERMINATED_QUOTE Lexer.ENH-002: '...' or "..." not closed
0xFFFFECC2  LX_ERR_INVALID_ESCAPE     Lexer.ENH-002: `\` at end of input
0xFFFFECC3  LX_ERR_BAD_ARGS           Lexer.ENH-002: input_ptr==0 && len>0
0xFFFFECD0  PR_ERR_TOO_MANY_STAGES    Parser.ENH-003: >PR_MAX_STAGES (8) stages
0xFFFFECD1  PR_ERR_LEADING_PIPE       Parser.ENH-003: line starts with `|`
0xFFFFECD2  PR_ERR_TRAILING_PIPE      Parser.ENH-003: line ends with `|`
0xFFFFECD3  PR_ERR_EMPTY_STAGE        Parser.ENH-003: `|| ` -- empty stage
0xFFFFECD4  PR_ERR_ARGV_POOL_OVERFLOW Parser.ENH-003: words > _pr_argv_pool (4096)
0xFFFFECE0  BI_MISS                   Dispatch.ENH-004: no builtin matched argv[0] (try external)
0xFFFFECE1  BI_ERR_CD_NO_ARG          Builtins.ENH-004: `cd` invoked with no path
0xFFFFECE2  BI_ERR_CD_FAIL            Builtins.ENH-004: sys_chdir returned negative errno
0xFFFFECE3  BI_ERR_EXIT_BAD_CODE      Builtins.ENH-004: `exit` argv[1] not decimal
0xFFFFECE4  BI_ERR_EXPORT_MALFORMED   Builtins.ENH-004: `export` argv[1] no '=' or empty name
0xFFFFECE5  BI_ERR_EXPORT_TABLE_FULL  Builtins.ENH-004: env table at BI_ENV_TABLE_MAX (32)
0xFFFFECE6  BI_ERR_EXPORT_POOL_FULL   Builtins.ENH-004: env name+value > 4096-byte pool
0xFFFFECE7  BI_ERR_PWD_TOO_LONG       Builtins.ENH-004: sys_getcwd returned negative errno
```

(Sub-bands `0xFFFFECAx` (ReleaseManifest) and `0xFFFFECBx` (BrokerBind)
sit between CMDR and LX; see the M5 sections above for their full
tables.)

The band sits below libpdx-elevate's `0xFFFFEA00..0xFFFFEA0F` and
above libpdx-cap's `0xFFFFFFxx` so a downstream consumer can tell
which layer refused the operation from the high two bytes of the
return alone.

## 6. paideia-as conformance

Every function in shell src/ obeys the constraints in
`design/kernel/paideia-as-conformance.md` (paideia-os):

- Module names PascalCase basename (`Shell`, `LineReader`, `Exec`); no
  directory prefix.
- No `test` mnemonic; every zero-check uses `cmp reg, 0`.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`. The M1 skeletons
  compare against small immediates only (`cmp rdi, 0`, `cmp rcx, 8`);
  the stub return sentinels (`0xFFFFEC10`, `0xFFFFEC11`, ...) are
  `mov rax, imm32` emissions, not compares.
- Byte reads use `xor rax, rax; mov_b rax, [ptr]` (#1248 mitigation).
  M1's skeletons make no byte reads; the pattern will show up at M2
  once the line reader consumes KIND_TTY bytes.
- SysV push/pop parity preserved. All M1 skeleton functions are LEAF
  functions (no nested calls) except `shell_reset` (which calls
  nothing) and the wrappers that call `shell_note` (one `sub rsp, 8` +
  `add rsp, 8` bracket around the nested call for 16-byte stack
  alignment — same idiom as `elevate_client_lookup_broker`).

## 7. Testing (M4 landed)

Three test modules ship under `tests/`, each covering one M4 issue:

### 7.1 `tests/test_caps_narrow.pdx` — shell.M4-001 (#12)

`TestCapsNarrow` module drives 8 test cases against
`Exec.exec_narrow_child_caps` (M2-003). Each case is a pure-function
driver: build wire-form fixtures in .bss via MOV constants, call the
narrower, verify return code (and, for OK cases, verify dst bytes;
for reject cases, verify the poison sentinel 0xDEADBEEF at dst[0]
survives).

The 8 cases exhaust the equivalence classes the narrower must
distinguish:

- HAPPY, NARROWING (rights intersected downward), MISSING_CAP
  (child asks for a KIND parent doesn't hold), WIDENING (child
  asks for rights parent doesn't hold), SIDECAR_FULL (dst too
  small), ZERO_DECL (child needs only ambient session cap; valid),
  BAD_ARGV_PARENT (null parent pointer), BAD_ARGV_DECL (null decl
  pointer).

Umbrella driver `tcn_run_all` returns 0 on all-pass or the first
`TCN_FAIL_*` (0xFFFFED0x band) on failure.

### 7.2 `tests/test_audit_first.pdx` — shell.M4-002 (#13)

`TestAuditFirst` module drives 8 test cases against
`CommandRecord.command_record_begin` and `command_record_close`
(M3-003). Each case exercises one gate or one round-trip property.

The load-bearing case is `taf_case_ordering`: begin then close then
verify every one of the six header qwords AND the argv tail bytes.
This case proves the encoder pair round-trips correctly — OPEN →
CLOSED with the mutable fields (ts_end, exit_code, flags) updated
and the immutable fields (magic, record_len, audit_id, ts_begin,
argv_bytes, argv tail) preserved. The remaining 7 cases isolate
individual gates so a failure names the specific one.

The `taf_case_close_pending` case is the semantic invariant for the
PENDING sentinel: a caller cannot pass `CMDR_EXIT_PENDING`
(0xFFFFFFFF) as a legitimate exit code, so a CLOSED record never
displays the "still running" marker in the exit field.

Umbrella driver `taf_run_all` returns 0 or a `TAF_FAIL_*`
(0xFFFFED1x band).

### 7.3 `tests/test_smoke_matrix.pdx` — shell.M4-003 (#14)

`TestSmokeMatrix` module produces + validates the encoder-half wire
bytes for the `ls | cat` QEMU smoke scenario. Four cases:

- `tsm_case_pipeline`: pipeline_plan for 2 stages → 2 wire entries
  paired on pipe id 0.
- `tsm_case_ls_cmdrec`: begin/close for `ls` (audit_id=0x1001,
  argv="ls\0", exit=0).
- `tsm_case_cat_cmdrec`: begin/close for `cat` (audit_id=0x1002,
  argv="cat\0", exit=0).
- `tsm_case_hist`: history_encode_record for "ls | cat" (8 bytes,
  record_len 32).

Every golden value is derived by hand from the wire-format specs
(§3b, §4c, §4d, §4e above) and pinned in-source as
`mov r11, imm64; cmp rax, r11`. A drift in any encoder fires
immediately.

The SUBSTRATE half of the smoke — booting QEMU, scripting an
interactive `login → prompt → ls | cat → reboot → history` session
against a serial console — lives on the paideia-os side (M4+
harness in `tools/verify-user-shell.sh` per `.plans/m4-003-notes.md`).
The shell repo's `tsm_run_all` is the pre-QEMU gate: if the encoder
golden bytes don't match, there's no point booting the guest.

### 7.4 Fail-code bands

- `0xFFFFED0x` — TestCapsNarrow (M4-001).
- `0xFFFFED1x` — TestAuditFirst (M4-002).
- `0xFFFFED2x` — TestSmokeMatrix (M4-003).
- `0xFFFFED3x` — TestReleaseManifest (M5-001).
- `0xFFFFED4x` — TestSyscallFloor (ENH-001, #28).
- `0xFFFFED5x` — TestLexer (ENH-002, #29).
- `0xFFFFED6x` — TestParser (ENH-003, #30).
- `0xFFFFED7x` — TestBuiltins (ENH-004, #31).

These are disjoint from the shell's own `0xFFFFECxx` band so an
operator reading a test-run log can tell "SUT rejected input" from
"test framework detected the SUT did the wrong thing" by the high
two bytes of the return alone.

### 7.5 What M4 deferred to M5 substrate

M4 test-code is pure-function driven; the substrate wiring that
turns encoder halves into live runs stays deferred to a paideia-os
round adjacent to R49:

- Userspace `sys_execve`/`sys_wait4` wrappers.
- Userspace `sys_ipc_recv`/endpoint-mint (turns
  `pipeline_plan` placeholder pipe ids into real endpoint ids).
- Userspace PdxFS-write path (persists history via
  `svc.pdxfs-journal`).
- Userspace `sys_ipc_send` to `svc.audit-journal` (persists
  ShellCommandRecord).
- Cross-repo linkage of libpdx-cap / libpdx-audit /
  libpdx-semantic-pipe / libpdx-argv symbols into one build.

See `STATUS.md` §"Upstream substrate" for the substrate gaps M4
identifies and M5 (or a paideia-os round adjacent to R49)
closes.
