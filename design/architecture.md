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
`_start` frame calls in order:

- `Shell` (`src/shell.pdx`) — top-level orchestration, constants shared
  across the shell's modules, session-level state (bounded stats table,
  reset function), and the M1 skeleton for the run loop.
- `LineReader` (`src/line_reader.pdx`) — the interactive line reader.
  Wraps the semterm engine's line editor
  (paideia-os `src/kernel/core/semterm/line_editor.pdx`, R41.M4-002)
  from userspace, exposing `line_reader_read_line(buf, buf_len) → u64`.
  M1 ships the SKELETON: prompt-render + buffer wiring returns
  `LR_STUB`; the actual byte-source binding to KIND_TTY(read) and the
  echo-back to KIND_TTY(write) land at M2 once the KIND_TTY substrate
  in the paideia-os kernel is ready to service userspace.
- `Exec` (`src/exec.pdx`) — the exec path. `exec_spawn_and_wait(argv,
  argv_count) → u64` assembles an InitCap sidecar for the child,
  invokes `sys_execve`, blocks on `sys_wait4`, and returns the exit
  code. M1 ships the SKELETON: argv gating returns `EX_STUB`; the
  actual sys_execve call lands at M2 alongside the pipeline substrate
  (`|` mint of `KIND_IPC_ENDPOINT`).

The shell's `_start` frame (not part of M1 — the loader's entry
convention lands in the paideia-os R14b bootstrap) calls the three
modules in this order:

```
1. Shell::shell_reset()                       // clear stats
2. loop:
     let n = LineReader::line_reader_read_line(cmd_buf, 256)
     if n == 0 { exit 0 (EOF) }
     let rc = Exec::exec_spawn_and_wait(cmd_buf, n)
     // rc is the child's exit code (or an EX_ERR_* code)
```

At M1 both `line_reader_read_line` and `exec_spawn_and_wait` return
their `_STUB` code so the harness in tests/ can call the run loop
without blocking on a live TTY or live process.

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

## 3. `LineReader` module (src/line_reader.pdx)

### 3.1 Contract

```
line_reader_read_line(buf: u64, buf_len: u64) -> u64
```

- Read one line from the shell's stdin (bound to KIND_TTY at M2) into
  `buf`, echo bytes back to KIND_TTY as the user types.
- Returns the number of bytes written on success (0..buf_len).
- Returns 0 on EOF (`Ctrl-D` on an empty line).
- Returns an `LR_ERR_*` code (0xFFFFECxx band) on error.

### 3.2 M1 skeleton

M1 ships the wrapper shape and refuses `buf == 0 || buf_len == 0` with
`LR_ERR_BAD_BUF`. On the happy path it returns `LR_STUB`
(0xFFFFEC10) — the "we validated the args, we would render a prompt
and read bytes if the KIND_TTY substrate existed, but it doesn't yet"
signal. This mirrors libpdx-elevate's `ELVC_STUB` idiom: the request
is validated up to the substrate boundary, no fake bytes are
manufactured, and the caller learns unambiguously that M1 stopped
one step short of a real read.

`line_reader_read_line` bumps `SH_ST_PROMPTS` on every entry and
`SH_ST_ERRORS` on every reject path so the shell's own stats table
records the failure without needing the caller to touch a journal.

### 3.3 Interaction with the semterm engine

At M2, `line_reader_read_line` will call into the semterm line editor
(paideia-os `src/kernel/core/semterm/line_editor.pdx`, R41.M4-002)
one keypress at a time: `led_reset` at line start; `led_insert(ch)`
for each printable byte; `led_backspace` / `led_delete` /
`led_left` / `led_right` / `led_home` / `led_end` for cursor motion
keys; `led_history_up` / `led_history_down` for history browsing;
`led_kill_line` / `led_yank` for the kill register. On `\n` (0x0A),
`led_history_push` snapshots the buffer and the line is returned to
the caller. The M1 skeleton predates the KIND_TTY wire that carries
those keypresses, so the call graph is documented but not yet built.

## 4. `Exec` module (src/exec.pdx)

### 4.1 Contract

```
exec_spawn_and_wait(argv: u64, argv_count: u64) -> u64
```

- Spawn a child from `argv[0]` with the caller-owned `argv[]` array.
- Block on the child's exit, return its exit code (0..255).
- Returns an `EX_ERR_*` code (0xFFFFECxx band) on error.

### 4.2 M1 skeleton

M1 gates `argv != 0 && argv_count != 0` and returns `EX_STUB`
(0xFFFFEC20) on the happy path — the "we validated the args, we would
call sys_execve if we had a userspace sys_execve wrapper linked, but
we don't yet" signal.

Same skeleton discipline as `LineReader`: `SH_ST_SPAWNS` bumps on
entry, `SH_ST_ERRORS` bumps on reject.

### 4.3 M2 evolution

At M2, `exec_spawn_and_wait`:

1. Assembles an InitCap sidecar for the child (16-byte records per
   paideia-os `src/kernel/core/loader/init_caps.pdx`; layout matches
   libpdx-cap's wire format at `src/cap.pdx`).
2. Narrows each parent-held cap per the callee's caps.decl using
   `libpdx-cap::cap_manifest_verify`.
3. Calls `sys_execve(path, argv, envp, initcap_sidecar)`.
4. On success, blocks on `sys_wait4(pid, wstatus, 0, 0)`.
5. Returns `wstatus & 0xFF` as the exit code.

M2 also lands the pipeline shape (`a | b | c`), minting one
`KIND_IPC_ENDPOINT` per `|` and splicing it into the paired children's
stdin/stdout via a second InitCap sidecar entry.

## 5. Return-code band `0xFFFFECxx`

```
0xFFFFEC00  SH_OK               general success sentinel (unused at M1)
0xFFFFEC10  LR_STUB             LineReader.M1: validated, no live read yet
0xFFFFEC11  LR_ERR_BAD_BUF      buf == 0 or buf_len == 0
0xFFFFEC12  LR_ERR_TTY_UNBOUND  M2+: KIND_TTY(read) missing from caller
0xFFFFEC13  LR_ERR_EOF          M2+: sys_read on TTY returned 0 unexpectedly
0xFFFFEC20  EX_STUB             Exec.M1: validated, no live spawn yet
0xFFFFEC21  EX_ERR_BAD_ARGV     argv == 0 or argv_count == 0
0xFFFFEC22  EX_ERR_EXECVE_FAIL  M2+: sys_execve refused the child
0xFFFFEC23  EX_ERR_WAIT_FAIL    M2+: sys_wait4 returned an unexpected code
```

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

## 7. Testing

Tests land at M4 (per §5.2 M4 in the plan doc). M1 ships
`tests/README.md` as a placeholder describing the fixture matrix M4
will populate:

- Pipeline correctness matrix (2-stage, 3-stage, cross-schema).
- Caps-narrowing test (child receives no cap not declared in its
  caps.decl).
- Audit-first invariant (child cannot emit before audit record is
  durable).
- `.pds` script test suite (per `design/terminal/pds-format.md`).
- QEMU smoke: interactive login → prompt → `ls | cat` →
  history-persist.
