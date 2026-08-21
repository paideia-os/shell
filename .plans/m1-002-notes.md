# shell.M1-002 — implementation notes

**Issue:** #2
**Status:** LANDED
**Landed by:** Fix #2

## What landed

- `src/line_reader.pdx` — `LineReader` module:
  - `line_reader_read_line(buf, buf_len) → u64` — validates the
    caller's buffer, bumps `SH_ST_PROMPTS` on entry, returns
    `LR_STUB` (0xFFFFEC10) on the happy path and `LR_ERR_BAD_BUF`
    (0xFFFFEC11) with `SH_ST_ERRORS` bump on reject.

## Design decisions

### Why LR_STUB on the happy path

`KIND_TTY` has not landed in the paideia-os kernel at HEAD
(2026-08-21). `kind_tty.pdx` does not exist in
`src/kernel/core/cap/`. There is no userspace `sys_read` wrapper
that lets the shell block on a TTY byte source. Two options for
M1's happy path:

1. Fake a byte source — link against a canned test buffer, or
   manufacture bytes in-place. Both lie to the shell's audit
   journal at M3 ("shell claims to have read a line the user
   never typed"). Refused.

2. Skeleton — validate every part of the call graph that is not
   the substrate boundary, return a stub sentinel at the
   boundary. This is the pattern libpdx-elevate documents at
   length in `src/elevate_client.pdx` §"WHY STUB IS THE HAPPY
   PATH AT M1", and it is the pattern this module follows.

The M2 body replaces the LR_STUB tail with the sys_read +
`led_insert` dispatch loop; every consumer already spells
`line_reader_read_line` correctly at its call site.

### M2 call graph (documented, not built)

The header comment §"M2 CALL GRAPH" documents the sys_read loop,
the byte-dispatch table (printable → `led_insert`; `\n` →
`led_history_push` + return; `\b`/DEL → `led_backspace`; Ctrl-D
on empty → return 0 EOF; ESC-[ arrows → `led_left`/`led_right`/
etc.; Ctrl-K → `led_kill_line`; Ctrl-Y → `led_yank`), and the
per-dispatch redraw to KIND_TTY(write). This is documentation
work M1 does so M2 is a body edit rather than a design pass.

### Prologue shape

Two callee-save pushes (r12 = buf, r13 = buf_len) preserve the
args across the nested `shell_note` call. `sub rsp, 8` balances
rsp % 16 to 0 for the SysV call (two pushes = 16 bytes; one sub 8
= 8 bytes; total 24 bytes lands rsp on a 16-byte boundary from
its call-entry state of 8 bytes off). Matched `add rsp, 8` before
the pops. Same idiom as `elevate_client_lookup_broker` in
libpdx-elevate.

### SH_ST_PROMPTS bump is unconditional

Every ENTRY is a prompt attempt, whether or not the args gate
succeeds. The shell wants to see attempt-not-success in its
stats table because a repeated `LR_ERR_BAD_BUF` from a caller
with a bad buffer is a bug the operator should be able to see
without diffing a journal. Same rationale as
`elevate_client_lookup_broker` bumping `ELVC_ST_LOOKUPS` before
the miss compare.

## paideia-as conformance checklist

- Module name PascalCase basename (`LineReader`): yes.
- No `test` mnemonic: verified — the only compares are `cmp r12, 0`
  and `cmp r13, 0`, both use `cmp reg, 0` (small immediate).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Large-immediate stub sentinels (`0xFFFFEC10`, `0xFFFFEC11`) are
  `mov rax, imm32` emissions.
- `r11` scratch: not needed in this module.
- Byte reads: none in M1; the `xor rax, rax; mov_b rax, [ptr]`
  pattern lands at M2 with the sys_read loop.
- Two callee-save pushes (r12 + r13) with matched pops on every
  return path. `sub rsp, 8` / `add rsp, 8` bracket the nested
  `shell_note` call for SysV alignment.

## What M2 builds on top

- Replace the LR_STUB tail with:
  ```
  call led_reset
  # emit prompt to KIND_TTY(write)
loop:
  # sys_read one byte from KIND_TTY(read)
  # dispatch by byte per M2 CALL GRAPH
  # redraw
  # if committed, copy led buffer to caller's r12 buf, return length
  ```
- Add stats slot `SH_ST_LINES` bump on successful commit.
- Add `LR_ERR_TTY_UNBOUND` / `LR_ERR_EOF` paths.
