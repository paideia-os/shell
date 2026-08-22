# shell.M4-002 — implementation notes

**Issue:** #13
**Title:** audit-first invariant test (child cannot emit before audit
is durable)
**Status:** LANDED
**Landed by:** Fix #13

## What landed

- `tests/test_audit_first.pdx` — `TestAuditFirst` module: 8 test cases
  against `CommandRecord.command_record_begin` and
  `command_record_close` (M3-003), plus the umbrella `taf_run_all`
  driver.

  Cases (all named `taf_case_*`):

  | # | Name              | Verifies                                                          |
  |---|-------------------|-------------------------------------------------------------------|
  | 1 | begin_ok          | begin produces well-formed OPEN header; all 6 qwords match golden |
  | 2 | close_exit0       | close(exit=0): ts_end, exit=0 in high 32, CLOSED, no HAS_ERROR    |
  | 3 | close_exit1       | close(exit=1): exit=1 in high 32, CLOSED | HAS_ERROR             |
  | 4 | close_no_begin    | close with dst_len < CMDR_HEADER_SIZE → CMDR_ERR_BAD_ARGS         |
  | 5 | close_exit_oor    | close(exit=256) → CMDR_ERR_BAD_EXIT                               |
  | 6 | begin_id_zero     | begin(audit_id=0) → CMDR_ERR_BAD_ARGS                             |
  | 7 | close_pending     | close(exit=0xFFFFFFFF) → CMDR_ERR_BAD_EXIT                        |
  | 8 | ordering          | begin+close round-trip: all 6 header qwords + argv tail preserved |

  Fixture buffers in .bss:
  - `_taf_rec` — 128 bytes (16 qwords) for the record.
  - `_taf_argv` — 8 bytes for the "ls\0-l\0" (6-byte) argv fixture.

  `taf_reset` zeroes `_taf_rec` and re-populates `_taf_argv` with
  bytes 0x6c, 0x73, 0x00, 0x2d, 0x6c, 0x00.

  Fail codes in the 0xFFFFED1x band:
  - `TAF_FAIL_BEGIN_OK` (0xFFFFED11), `TAF_FAIL_CLOSE_E0` (…12),
    `TAF_FAIL_CLOSE_E1` (…13), `TAF_FAIL_NO_BEGIN` (…14),
    `TAF_FAIL_EXIT_OOR` (…15), `TAF_FAIL_ID_ZERO` (…16),
    `TAF_FAIL_EXIT_PEND` (…17), `TAF_FAIL_ORDER` (…18).

## Design decisions

### Encoder half only

The full D3 audit-first invariant has two halves:

1. **Encoder produces a well-formed record.** Tested here.
2. **libpdx-audit's send-with-durable-ack path** makes the record
   durable on the journal broker BEFORE `sys_execve` unblocks the
   child. Tested at M4+ substrate time in libpdx-audit's own test
   suite + the paideia-os side smoke harness.

This split is deliberate: the encoder can be exhaustively tested
against golden bytes without a live journal broker; the durability
half requires the broker to be spun up as a supervisor process and
tested for the send-then-ack race. Splitting keeps the test surface
per module small enough to reason about.

### The ORDERING case as the "load-bearing" round-trip

Cases 1-7 test individual gates. Case 8 (`taf_case_ordering`) does
the full round-trip: begin followed by close, then verifies EVERY
field of the final record, including the argv tail bytes at offset
48..53 (which begin's byte-copy loop wrote and close never touches).

If any single-field test passes but ordering fails, there's a memory-
corruption interaction between begin and close that individual tests
would miss. This mirrors the "smoke test as regression net" pattern
in kernel testing — a full-scenario test catches emergent bugs the
unit tests miss by design.

### The PENDING sentinel test (case 7)

Same underlying gate as case 5 (exit_code > 255 rejected), but a
DISTINCT test entry documents the SEMANTIC invariant: the wire's
PENDING marker 0xFFFFFFFF is a reader-observable sentinel; a caller
cannot produce a CLOSED record that displays 0xFFFFFFFF where the
exit code should be. If a future refactor changed the exit ceiling
(say, to allow 24-bit exit codes for POSIX compatibility), case 5
would need updating but case 7's invariant would still hold — the
PENDING sentinel must never round-trip through close.

### The NO_BEGIN case (case 4)

This is a subtle security-adjacent test. Without the gate
`dst_len >= CMDR_HEADER_SIZE`, a caller could pass an 8-byte buffer
and close would attempt to update qword2 (ts_end at offset 24) and
qword5 (flags at offset 40) — both writes going past the buffer end.
On paideia-os with strict memory protection this would trap; without
strict protection it would corrupt whatever sat at those offsets.
The test asserts the gate refuses with CMDR_ERR_BAD_ARGS before any
memory write.

### AUDIT_ID_ZERO test (case 6)

libpdx-audit reserves audit_id 0 as "no active audit". This is a
class of contract violation: a caller passing uninitialised memory,
or a caller trying to fabricate an audit record without going through
libpdx-audit's `audit_begin` (which never issues id 0). Either way,
the encoder must refuse before writing any wire bytes.

### Golden qword0 = 0x00000038_52444d43

Computed by hand from the wire format spec:

- Magic = 0x52444d43 (little-endian "CMDR": 'C'=0x43, 'M'=0x4D,
  'D'=0x44, 'R'=0x52 → u32 = 0x52444d43).
- record_len = (48 + 6 + 7) & ~7 = 56 = 0x38.
- qword0 = magic | (record_len << 32) = 0x52444d43 |
  (0x38 << 32) = 0x0000003852444d43.

The value is written to the test as `mov r11, 0x0000003852444d43` so
the exact bit pattern is inspectable in the source without needing to
run the test. This is how every golden value in this module is
derived; the wire-format spec in `src/command_record.pdx` §WIRE
FORMAT is the reference.

## paideia-as conformance checklist

- Module name PascalCase basename (`TestAuditFirst`): yes.
- No `test` mnemonic: yes.
- Every `cmp reg, imm` uses imm <= 0x7FFFFFFF: yes (largest is 256
  in taf_case_close_exit_oor, and the exit_code comparison there
  is `cmp reg, imm` with imm = 256 = 0x100).
- Large immediates (CMDR_MAGIC, CMDR_EXIT_PENDING, error codes,
  fail codes, TS_BEGIN/TS_END fixture constants) via
  `mov r10, imm64` / `mov r11, imm64`.
- `r11` scratch for `lea r11, [rip + sym]` reaches and for holding
  expected values in verifier compares.
- Byte reads use `xor rax, rax; mov_b rax, [ptr]` in the ordering
  case's argv-tail verifier.
- Byte writes in `taf_reset` use `mov_b [ptr], rax` after loading
  rax with the byte constant.
- Every non-leaf test entry: 6 pushes + `sub rsp, 8` = 56 bytes
  prologue; rsp % 16 == 0 for the SysV command_record_* calls.

## What later milestones build on top

- **M4-003 QEMU smoke** — `taf_run_all` is one of the pre-QEMU gates;
  a non-zero return means the encoder's fingerprint has drifted and
  the smoke's post-boot audit-journal check would fail.
- **M5-001 dual-signed release** — the paideia-as build lint at
  release time re-runs `taf_run_all` to confirm the D3 invariant
  still holds against the final release binary.
- **libpdx-audit.M4** — libpdx-audit's own test suite will pair this
  module's golden byte fixtures with the send-with-ack path, running
  full end-to-end (encoder → sender → durable-ack → SUT unblocks).
  The shell test provides the "input side" of the pairing; libpdx-
  audit's test provides the "output side".
- **undo (R51+)** — the audit journal's ShellCommandRecord format is
  what `undo` scans to reverse a command. The CLOSED + HAS_ERROR flag
  semantics tested here (a failed command has HAS_ERROR set; undo
  skips those) is the load-bearing contract for R51's undo replay.
