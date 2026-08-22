# shell.M3-003 — implementation notes

**Issue:** #11
**Status:** LANDED
**Landed by:** Fix #11

## What landed

- `src/command_record.pdx` — `CommandRecord` module:
  - Constants: `CMDR_HEADER_SIZE = 48`, `CMDR_ARGV_MAX = 8192`,
    `CMDR_MAGIC = 0x52444d43` (little-endian "CMDR"),
    `CMDR_EXIT_PENDING = 0xFFFFFFFF`.
  - Flag bits: `CMDR_FLAG_CLOSED = 0x1`, `CMDR_FLAG_HAS_ERROR = 0x2`.
  - Error band 0xFFFFEC9x: `CMDR_ERR_BAD_ARGS` (0xFFFFEC90),
    `CMDR_ERR_TOO_LONG` (0xFFFFEC91), `CMDR_ERR_TRUNCATED`
    (0xFFFFEC92), `CMDR_ERR_BAD_EXIT` (0xFFFFEC93).
  - Two entry points (no `.bss` singleton — the caller already
    knows record_len from the compute formula, unlike the other
    M2/M3 encoders where the padding formula makes recompute
    awkward):
    - `command_record_begin(dst, dst_len, argv_ptr, argv_bytes,
      audit_id, ts_begin_ns) → rc` — writes the OPEN record with
      `CMDR_EXIT_PENDING` in the exit_code field.
    - `command_record_close(dst, dst_len, ts_end_ns, exit_code) →
      rc` — updates ts_end_ns + exit_code + CLOSED (+ HAS_ERROR
      when exit_code != 0) in place.
- `src/shell.pdx` — new counter `SH_ST_AUDITS = 10` (stats table
  already widened to 16 by M3-001). Both begin and close bump
  this counter, so a paired begin/close is 2 audit events —
  matching the two round trips to the audit journal in the M4+
  substrate.
- `design/architecture.md` — new §4e documenting the CommandRecord
  module contract, wire format, exit-code sentinel, error codes,
  and substrate deferral.

## Design decisions

### Two-phase record

Per D3 audit-first in `design/tooling/r49-r50-plan.md` §1: every
operation journals to `/system/audit/user-events/` BEFORE it
emits any user-visible output. For `exec_spawn_and_wait` that
means the ShellCommandRecord must be durable before `sys_execve`
returns. But the exit code isn't known until after `sys_wait4`.
The two-phase design (begin BEFORE execve, close AFTER wait)
lets the record be durable at the right moment while still
recording the exit code that only becomes known later.

### CMDR_EXIT_PENDING sentinel

`0xFFFFFFFF` marks "record open, wait has not returned yet." A
reader sees this alongside the CLOSED flag being unset and knows
the child is either still running or the shell crashed between
begin and close (truncated record). Both are diagnosable states,
not silent corruption. The sentinel is above the legal exit range
(wstatus low byte 0..255) so it cannot collide with a real exit.
The close path rejects exit_code > 255 with `CMDR_ERR_BAD_EXIT`,
so a caller cannot accidentally write the sentinel value into
the record post-close.

### Six-qword fused header

- qword0: `magic | (record_len << 32)`
- qword1: `audit_id`
- qword2: `ts_begin_ns`
- qword3: `ts_end_ns` (0 at begin; updated by close)
- qword4: `argv_bytes | (exit_code << 32)` — argv_bytes low 32,
  exit_code high 32 (starts as CMDR_EXIT_PENDING, updated by close)
- qword5: `flags | (reserved << 32)` — 0 at begin; CLOSED (+
  HAS_ERROR when non-zero exit) after close

Six qword-atomic writes on begin; two writes on close (qword2
ts_end_ns, qword4 argv_bytes|exit_code, qword5 flags — actually
three writes on close, my apologies to the reader).

Actually: close writes THREE qwords (qword3 = ts_end_ns at
offset 24; qword4 = argv_bytes|exit_code at offset 32; qword5 =
flags at offset 40). Each is a single MOV to the wire; cross-qword
tearing is possible but the CLOSED flag serves as the schema-level
memory-order fence — a reader observing CLOSED can trust the
other three; a reader not observing CLOSED treats the record as
pending regardless of what those qwords hold.

### Close-path in-place update discipline

The close does NOT re-verify magic, record_len, audit_id, or
argv_bytes. The trust model is that the shell's exec dispatcher
pairs begin/close inside one stack frame and does not lose the
pointer between them. Re-verifying would double the work and
force a load-compare of the header on every close.

The close path also does not scan or re-copy the argv tail; it
only touches the three qwords above. That's why the close's
prologue is 3 pushes (versus begin's 5) — no `rbx` for a copy
loop, no `r15` for a fused-qword staging register.

### qword4 in-place preservation trick

The close preserves argv_bytes in the low 32 bits of qword4 while
replacing the sentinel in the high 32 with the real exit_code:

```
mov rax, [r12 + 32];     // load existing qword4
shl rax, 32;             // drop high 32
shr rax, 32;             // rax = argv_bytes (low 32)
mov r10, r13;            // exit_code
shl r10, 32;             // exit_code << 32
or  rax, r10;
mov [r12 + 32], rax;     // store back
```

This preserves the "single MOV atomic against a same-qword reader"
property. A concurrent reader either sees the old qword4 (both
argv_bytes and sentinel; record still pending) or the new qword4
(both argv_bytes and real exit_code); no torn field.

### audit_id == 0 refused

libpdx-audit reserves audit_id 0 as "no active audit". A caller
that tries to journal a record with audit_id 0 is either passing
uninitialized memory or trying to fabricate an audit record
without going through `audit_begin`. Both are contract violations;
BAD_ARGS is the correct response.

### argv_bytes == 0 permitted

Per D3 audit-first, the shell must journal even an "Enter on
empty prompt" event. `argv_bytes == 0` (with `argv_ptr` also
allowed to be 0) is a legitimate legal call.

## paideia-as conformance checklist

- Module name PascalCase basename (`CommandRecord`): yes.
- No `test` mnemonic: verified — every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes; the largest
  is CMDR_ARGV_MAX (8192).
- Large immediates (`CMDR_MAGIC = 0x52444d43`,
  `CMDR_EXIT_PENDING = 0xFFFFFFFF`, error codes
  `0xFFFFEC90..93`) via `mov r10, imm32` / `mov rax, imm32`.
- `r11` unused in either function body (no `.bss` reach).
- Byte reads / writes use `xor rax, rax; mov_b rax, [ptr]` and
  `mov_b [ptr], rax` in the argv-copy loop and zero-pad loop
  (begin only; close does not touch bytes below the header).
- `command_record_begin`: 5 pushes (rbx, r12, r13, r14, r15) +
  `sub rsp, 8` = 48 bytes prologue; rsp % 16 == 0 for
  shell_note. Matched epilogue.
- `command_record_close`: 3 pushes (r12, r13, r14) + `sub rsp, 8`
  = 32 bytes prologue; rsp % 16 == 0 for shell_note. Matched
  epilogue.

## What later milestones build on top

- M4-002 audit-first invariant test: the shell's exec dispatcher
  MUST call `command_record_begin` and receive libpdx-audit's
  durable-write acknowledgement BEFORE `sys_execve`. The test
  installs a fault-injection at libpdx-audit's send path and
  verifies that a rejected send makes the shell refuse to exec
  the child (exit code 3 per I4 system error).
- M4-003 QEMU smoke: `ls | cat` produces TWO ShellCommandRecords
  (one for `ls`, one for `cat`). The smoke checks that both
  records appear in the audit journal in the correct order and
  that each has a CLOSED flag with the correct exit code.
- Cross-repo linkage: the shell M3 keeps the encoder
  self-contained. M4 pulls libpdx-audit into the same build so
  `command_record_begin` can call `audit_begin` and
  `command_record_close` can call `audit_commit`.
- `undo` (R51+): the audit journal is what `undo` scans to
  reverse a command. A CLOSED ShellCommandRecord with HAS_ERROR
  is skipped (the command failed; nothing to undo); a CLOSED
  record with exit 0 is a candidate for reversal via the child's
  own undo protocol.
