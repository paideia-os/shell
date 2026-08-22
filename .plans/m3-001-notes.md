# shell.M3-001 — implementation notes

**Issue:** #9
**Status:** LANDED
**Landed by:** Fix #9

## What landed

- `src/pipe_passthrough.pdx` — `PipePassthrough` module:
  - Constants: `PP_HEADER_SIZE = 8` (R20b frame header),
    `PP_MAX_PAYLOAD = 0x7FFFFFF7` (paideia-as compare ceiling).
  - Error band 0xFFFFEC7x: `PP_ERR_BAD_ARGS` (0xFFFFEC70),
    `PP_ERR_TRUNCATED` (0xFFFFEC71), `PP_ERR_DST_OVERFLOW`
    (0xFFFFEC72), `PP_ERR_OVERSIZED` (0xFFFFEC73).
  - `.bss` singleton `passthrough_bytes_forwarded : u64`.
  - `pipe_passthrough_reset()` — zero the singleton.
  - `pipe_passthrough_forward(src, src_len, dst, dst_max) → rc`
    — copies one R20b frame verbatim; verifies header length and
    both buffer bounds before touching dst.
- `src/shell.pdx` — stats table extended from 8 to 16 slots;
  new counter `SH_ST_PASSTHRU = 8`. `shell_reset` / `shell_note`
  / `shell_stat` bound compares widened from 8 to 16.
- `design/architecture.md` — new §4c documenting the
  PipePassthrough module contract, wire format, passthrough
  discipline, and error codes.

## Design decisions

### Passthrough discipline (D2 literal)

The shell forwards typed pipes; it does not schema-erase them
into byte streams. Per `design/tooling/r49-r50-plan.md` §5.2 M3
line: "each child's schema pipe is forwarded unchanged to the
pipeline consumer (D2 literal)." Every byte of the frame — R20b
header, schema_hash prefix if the typed flag is set, record body
— is copied without decoding.

This choice keeps the shell independent of
libpdx-semantic-pipe's schema registry. A child at R56+ that
ships a new schema needs no shell rebuild to be pipeable to. The
same "wire-only, no linkage" discipline libpdx-cap M2 followed
for the Cap wire format.

### Load-header-as-qword

The R20b frame header is defined as one aligned 8-byte qword in
`paideia-os src/kernel/core/ipc/frame.pdx`. Loading it as
`mov rax, [r12 + 0]` and extracting payload_len via `shr rax, 32`
is one instruction each — versus the four-byte-load-plus-shift-or
composition that would be needed if the header layout were
byte-unaligned. This is legal because the paideia-os frame
convention guarantees 8-byte header alignment; the shell relies
on the same alignment its child stages produce.

### PP_MAX_PAYLOAD = 0x7FFFFFF7

The compare ceiling in paideia-as is `imm <= 0x7FFFFFFF`. The
maximum legal payload_len is `0x7FFFFFFF - 8 = 0x7FFFFFF7` so
`8 + payload_len` still fits in a u32 add without overflow. A
payload_len above this bound is malformed on the wire (a real
R20b frame's `payload_len` field is u32, so 2GiB-minus-8 is the
theoretical ceiling anyway).

### Byte-copy loop, not rep movsb

The inner copy loop uses the same `xor rax, rax; mov_b rax,
[src+rbx]; mov_b [dst+rbx], rax; inc rbx; jmp` pattern history.pdx
and libpdx-cap's caps_decl parser use. `rep movsb` is not in the
paideia-as M2 asm surface; a byte-wise loop is the portable idiom
and stays #1248-conformant.

### Fail-fast before any store to dst

All four gates (src null, dst null, dst_max zero, src_len < 8) fire
before the qword load of the header. Payload_len decode happens
next; if it exceeds PP_MAX_PAYLOAD, TRUNCATED gate, or DST_OVERFLOW
gate, the reject fires before any byte is written to dst. Same
discipline as libpdx-cap `cap_pack`.

## paideia-as conformance checklist

- Module name PascalCase basename (`PipePassthrough`): yes.
- No `test` mnemonic: verified — every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes; the largest
  is PP_MAX_PAYLOAD (0x7FFFFFF7), loaded via `mov r10, imm32` and
  compared reg-to-reg.
- Large immediates emitted via `mov r10, imm32` / `mov rax, imm32`.
- `r11` used only in the singleton-write LEA on the happy path.
- Byte reads / writes use `xor rax, rax; mov_b rax, [ptr]` and
  `mov_b [ptr], rax` in the copy loop — same #1248 mitigation
  history.pdx uses.
- 4 pushes (rbx, r12, r13, r14) + `sub rsp, 8` = 40 bytes
  prologue; rsp % 16 == 0 for shell_note. Matched epilogue at
  every return.

## What later milestones build on top

- M4-002 audit-first invariant test: the pipeline driver mints an
  audit_id, calls `command_record_begin`, then loops
  `pipe_passthrough_forward` per frame. The test verifies no byte
  is emitted downstream before the audit record is durable.
- M4-003 QEMU smoke: `ls | cat` uses this encoder per frame ls
  emits. The smoke checks that `cat`'s stdin bytes are exactly
  what `ls`'s stdout produced.
- Cross-repo linkage: the shell M3 keeps this module
  self-contained; the M4 build pulls libpdx-semantic-pipe into the
  same graph so a schema-aware reader in `query` (R51+) can consume
  the forwarded frames without a passthrough re-encode.
