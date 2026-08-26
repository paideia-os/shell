# shell

The paideia-os interactive shell: reads user commands, spawns tool
processes with the caller's capability environment narrowed per each
callee's `caps.decl`, and threads text-and-schema-and-cap layers
through semantic pipes.

## Synopsis

```
shell
shell <script.pds>
shell -c '<command>'
```

Source: `doc/shell.pdxdoc` SYNOPSIS. Entry symbol is
`Shell::shell_main` (`manifest.pdxproj`); the `_start` frame that
binds argv/envp/InitCap to the binary lands with the paideia-os R14b
bootstrap, so at v1.0.0 the three invocation shapes are the declared
contract, not yet a live dispatcher (see *Maturity* below).

## Description

`shell` is the process the login supervisor launches after
authenticating a user. It reads a line from the terminal (`KIND_TTY`),
parses it into a pipeline of one or more child commands, mints one
`KIND_IPC_ENDPOINT` per pipe operator, narrows the parent's capability
environment against each callee's `caps.decl`, invokes `sys_execve`,
waits for exit, and appends a `HistoryEntry` to `~/.history/`. At
session start it mints a `KIND_SHELL_SESSION` cap and derives a
sub-cap per child with rights masked to `READ | WRITE` but **not**
`MINT` (`SS_RIGHTS_ALL = 0x7` for the shell itself, `SS_RIGHTS_CHILD =
0x3` for children) — the child cannot derive further sub-caps. That
session cap is the correlation id an audit-journal reader uses to
reassemble a whole pipe of tools as one unit of work.

Every command execution is journaled to `/system/audit/user-events/`
via libpdx-audit **before** the child runs, and closed with the exit
code after `sys_wait4`. This is the D3 audit-first invariant: a child
cannot emit user-visible output until its `ShellCommandRecord` is
durable in the journal. A shell that cannot reach `svc.audit-journal`
refuses to spawn children and exits 3.

Semantic-pipe awareness here is *passthrough*, not translation. A
POSIX pipe is an anonymous file descriptor carrying bytes; a paideia-os
pipe is a `KIND_IPC_ENDPOINT` cap pair with declared read/write rights
and a `target_ptr` the child cannot forge, carrying an R20b frame whose
header flags whether a typed record follows. `PipePassthrough`
(`src/pipe_passthrough.pdx`) copies that frame verbatim — the shell
does **not** decode the schema, does not re-hash the `schema_hash`
prefix, and does not touch one byte of the payload. The module
deliberately does not link libpdx-semantic-pipe, so a tool shipping a
schema the shell has never seen is pipeable without a shell rebuild.
This is "D2 literal": typed pipes are forwarded, never schema-erased
into byte streams the downstream cannot re-type.

Elevate integration is *reserved*, and honestly so: `libpdx-elevate @
^0.2` is a declared dependency in `manifest.pdxproj` and
`SH_KIND_ELEVATE_CHANNEL = 0x191` is mirrored in `src/shell.pdx`, but
the shell does not request elevated caps at session start. The
dependency is pre-declared so that a future `.pds` asking for one via
`requires: elevate` needs no re-signing round to add it. At M5-001 the
shell registers itself with the service broker under the name
`svc.login-shell` (`src/broker_bind.pdx`), giving the login
supervisor's path a discoverable endpoint.

**Maturity.** v1.0.0 is the *encoder half* of the R49 wave. Every wire
format, cap-narrowing rule, and audit record in this repo is
implemented and golden-tested; the syscall substrate underneath is
deferred to a paideia-os round adjacent to R49. Concretely:
`line_reader_read_line` returns `LR_STUB` (0xFFFFEC10) because
`KIND_TTY` has not landed upstream; `exec_spawn_and_wait` returns
`EX_STUB` (0xFFFFEC20) because there is no userspace `sys_execve`
wrapper yet; `pipeline_plan`'s `target_ptr` carries placeholder pipe
ids; and PdxFS-write, `sys_ipc_send`, and the ML-DSA-65 release signer
are all pending. See `STATUS.md` for the full deferral list.

## Options

Declared in `doc/shell.pdxdoc` OPTIONS. There is no argv-parsing module
in `src/` at v1.0.0 — flag dispatch arrives with the `_start` frame —
so the Status column below is load-bearing.

| Option | Argument | Default | Description | Status |
|---|---|---|---|---|
| `-c` | `<command>` | — | Execute `<command>` once and exit. | declared |
| *(positional)* | `<script.pds>` | — | Execute a `.pds` script and exit; header parsed by `Pds` (`src/pds.pdx`), body dispatched through the normal pipeline path. | header parser landed |
| `--no-history` | none | off | Suppress `~/.history/` writes for this session. | declared |
| `--no-cap:<KIND>` | `<KIND>` name | none stripped | Strip the named capability at spawn time; passed through to every child (plan.md I6). | declared |

`shell` reads **no environment variables** — not `PATH`, not `PS1`,
not `IFS`. All configuration is either capability-driven (declared in
`caps.decl` at build time, honoured at exec via the InitCap sidecar) or
command-line driven. Environment variables are an ambient-authority
channel the project avoids per plan.md D5.

## Built-in commands

`shell` v1.0.0 ships **no builtin command table**. There is no
`builtin` symbol anywhere in `src/`, `caps.decl`, or
`design/architecture.md`: every word in a pipeline stage is resolved to
a binary and spawned through `Exec`. The in-process, non-spawning
surface is exactly this:

| Input | Effect | Source |
|---|---|---|
| Ctrl-D on an empty line | `line_reader_read_line` returns 0; the run loop exits 0 (EOF). | `design/architecture.md` §1; `src/line_reader.pdx` |
| Enter | Commits the line: `led_history_push`, copy editor buffer to the caller's buffer, return length. | `src/line_reader.pdx` |
| Tab | Raises a tab-completion request; candidates encode as `CommandCompletion` records. Ranker + schema-registry walk are M4 substrate. | `src/completion.pdx` |
| Ctrl-K / Ctrl-Y | `led_kill_line` / `led_yank`. | `src/line_reader.pdx` |
| Backspace, DEL, arrows, Home/End | `led_backspace`, `led_left`/`led_right`/`led_home`/`led_end`, history up/down. | `src/line_reader.pdx` |

Key dispatch is documented in `src/line_reader.pdx` as the M2 call
graph against the semterm line editor (paideia-os
`src/kernel/core/semterm/line_editor.pdx`, R41.M4-002); it is wired
when `KIND_TTY` lands. The `exit` shown in the `doc/shell.pdxdoc`
example session is the only builtin-shaped word named anywhere in the
repo and has no dispatch site in `src/` — treat it as illustrative.

## Semantic pipe output

The pipe operator is `|`. An N-stage pipeline `a | b | c` has N-1 pipe
operators and requires N-1 endpoints; `pipeline_plan` writes `2*(N-1)`
16-byte Cap wire records — for each pipe `p`, a `WRITE` cap on the
upstream stage's stdout and a `READ` cap on the downstream stage's
stdin, both carrying pipe id `p` as `target_ptr` so the loader-side
validator can pair them. A bare command is a valid pipeline of length
1 and produces 0 entries. `PL_MAX_STAGES = 8`.

Bytes crossing a pipe are R20b frames, mirrored in
`src/pipe_passthrough.pdx` from paideia-os `src/kernel/core/ipc/frame.pdx`:

```
+0  u8   op           opcode (SEND=1, RECV=2, ...; preserved as-is)
+1  u8   ver          version (currently 1)
+2  u16  flags LE     bit 0 = typed record follows
+4  u32  payload_len  bytes of payload after the header
```

`pipe_passthrough_forward(src, src_len, dst, dst_max)` forwards exactly
`8 + payload_len` bytes and records the count in
`passthrough_bytes_forwarded`. `PP_MAX_PAYLOAD = 0x7FFFFFF7`.

The shell publishes three schemas of its own (`caps.decl`
`declares_output_schemas`): `ShellPromptRecord` (one per interactive
prompt), `CommandCompletion` (one array per tab-completion request),
and `ShellCommandRecord` (one per command exec + wait). Forwarded child
schemas are *not* listed there — the shell is a conduit for those, not
their publisher.

`ShellCommandRecord` — 48-byte header + null-separated argv text +
0..7 zero pad, `record_len` always an 8-multiple
(`src/command_record.pdx`):

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
```

`command_record_begin` writes the record with `exit_code =
CMDR_EXIT_PENDING (0xFFFFFFFF)` before `sys_execve`;
`command_record_close` overwrites `ts_end_ns` and `exit_code` and sets
`CLOSED` (plus `HAS_ERROR` when the exit is non-zero) after
`sys_wait4`. The sentinel sits above the legal exit ceiling of 255, so
a reader seeing it with `CLOSED` unset knows the child is still running
or the shell died mid-record. `CMDR_ARGV_MAX = 8192`.

`CommandCompletion` — 16-byte header + UTF-8 candidate name + pad
(`src/completion.pdx`): `magic = 0x504d4f43` ("COMP" LE), `record_len`,
`u16 kind`, `u16 score` (0..1000), `u32 name_len` (max 512). Kind
vocabulary, closed at M3: `COMMAND=1`, `FILE=2`, `DIR=3`, `OPTION=4`,
`SCHEMA=5`; values 0 and 6..65535 fall back to plain-text rendering.

`HistoryEntry` — 24-byte header + UTF-8 command text + pad
(`src/history.pdx`), written to `~/.history/<session>-<ts>.pdxhist`:
`magic = 0x54534948` ("HIST"), `record_len`, `u64 ts_ns`, `u32 cmd_len`
(max 4096), `u32 flags` (bit 0 `HAS_ERROR`, bit 1 `SCRIPT`). Each
header qword is a single MOV, so a torn write inside one record is
impossible on x86-64.

## Exit codes

Process exit status (`doc/shell.pdxdoc` EXIT_STATUS):

| Code | Meaning |
|---|---|
| 0 | Success — the last child exited 0, or the shell exited cleanly. |
| 1 | Caller error — the shell detected a bad flag or bad script. |
| 2 | Usage — invoked with an unrecognised argument shape. |
| 3 | System error — audit-journal unreachable, `sys_execve` failed, broker registration refused. |
| 4 | Capability denied — a required cap was stripped or not held. |

Module entry points return a `u64` in the shell's own `0xFFFFECxx`
band, disjoint from the libpdx-cap band (`0xFFFFFFxx`), the
libpdx-elevate bands (`0xFFFFEAxx` / `0xFFFFE5Exx`), and the kernel
errno band — the high two bytes tell a consumer which layer refused.
Sub-bands: `1x` LineReader, `2x` Exec, `3x` Session, `4x` Pipeline,
`5x` Pds, `6x` History, `7x` PipePassthrough, `8x` Completion, `9x`
CommandRecord, `Ax` ReleaseManifest, `Bx` BrokerBind. Test drivers use
a disjoint `0xFFFFEDxx` band so a log distinguishes "the shell rejected
input" from "the test caught the shell doing the wrong thing". Full
table: `STATUS.md`.

## Capabilities

Requested at exec (`caps.decl`, verbatim):

```
requires:
- KIND_USER(read)
- KIND_TTY(write)
- KIND_IPC_ENDPOINT(mint)
- KIND_SHELL_SESSION(mint)
- KIND_PDXFS_FILE(write)
```

```
declares_output_schemas:
- ShellPromptRecord
- CommandCompletion
- ShellCommandRecord
```

Every `pub let` entry point in `src/` carries the same effect and
capability row:

```
!{mem} @{}
```

The modules are pure encoders and pure narrowers over caller-owned
buffers — no allocation, no syscalls, every counter in `.bss`. The
`KIND_*` requirements above are held by the *process*, not reached
through any function's capability row. `KIND_TTY` is named
symbolically because `kind_tty.pdx` has not landed upstream; the
provisional mirror `SH_KIND_TTY = 0x196` collides with `KIND_PDXFS_TXN`
and is pinned at the substrate PR (the M4 smoke matrix catches the
drift).

## Examples

An interactive session; the `ls | cat` pipeline is the canonical smoke
(`tests/test_smoke_matrix.pdx`), producing a 2-stage plan, two
`ShellCommandRecord`s, and one 8-byte `HistoryEntry`:

```
$ shell
paideia $ ls
...
paideia $ ls | cat > /tmp/files
paideia $ exit
```

One command, then exit — the whole run still journals a
`ShellCommandRecord` pair to `/system/audit/user-events/` before and
after the child:

```
$ shell -c 'grep foo /etc/hosts'
```

A `.pds` script. The header is a shebang plus a run of `#` pragmas
(`#capability`, `#requires-paideia`, `#import "<path>" as <n>`,
`#schema "<path>"`, `#ascii`), terminated by the first blank or
non-`#` line; the body is ordinary pipeline syntax. Limits are 16
capabilities, 8 imports, 8 schemas per script:

```
$ shell ~/bin/build-report.pds
```

Stripping a capability for the whole session, so no child can receive
it however its own `caps.decl` reads:

```
$ shell --no-cap:KIND_PDXFS_FILE < deploy.pds
shell: KIND_PDXFS_FILE stripped for this session
...
```

Installing the shell itself, which verifies the dual ML-DSA-65
signatures in `manifest.pdxsig` against `pkg keys`; a fingerprint
mismatch means the binary arrived through an unattested path and the
install should have been refused:

```
$ pkg install shell
```

## See also

- [libpdx-semantic-pipe](https://github.com/paideia-os/libpdx-semantic-pipe) — semantic-pipe envelope helpers; `Completion` builds against them, `PipePassthrough` deliberately does not link them.
- [libpdx-elevate](https://github.com/paideia-os/libpdx-elevate) — elevate-broker client, reserved for `.pds requires: elevate`.
- [libpdx-argv](https://github.com/paideia-os/libpdx-argv) — typed flag parser; `Pds` mirrors its `ParsedArgs` singleton discipline.
- [libpdx-cap](https://github.com/paideia-os/libpdx-cap) — `cap_pack_narrowed` / `cap_manifest_verify`, the narrowing checked at exec.
- [libpdx-audit](https://github.com/paideia-os/libpdx-audit) — `audit_begin` / `audit_commit`, wrapped by `CommandRecord`.
- [pkg](https://github.com/paideia-os/pkg) — package manager; installs and verifies `shell` itself.
- [ls](https://github.com/paideia-os/ls) — the sibling tool in the canonical `ls | cat` smoke.
- Local: `design/architecture.md` (module boundaries, wire formats, `0xFFFFECxx` band), `design/release-manifest.md`, `design/mirror-push.md`, `STATUS.md`, `CHANGELOG.md`.

## License

MIT — see LICENSE.
