# shell.M2-005 — implementation notes

**Issue:** #8
**Status:** LANDED
**Landed by:** Fix #8

## What landed

- `src/history.pdx` — `History` module:
  - `HIST_HEADER_SIZE = 24`, `HIST_CMD_MAX = 4096`,
    `HIST_MAGIC = 0x54534948` (little-endian "HIST").
  - Flag bits: `HIST_FLAG_HAS_ERROR = 0x1`, `HIST_FLAG_SCRIPT = 0x2`.
  - Error band 0xFFFFEC6x: `HIST_ERR_BAD_ARGS` (0xFFFFEC60),
    `HIST_ERR_TOO_LONG` (0xFFFFEC61), `HIST_ERR_TRUNCATED`
    (0xFFFFEC62).
  - `.bss` singleton `history_bytes_written : u64`.
  - `history_reset()` — zero the singleton.
  - `history_encode_record(dst, dst_len, cmd_ptr, cmd_len, ts_ns,
    flags) → rc` — serialise one HistoryEntry: 24-byte header (three
    qword-sized fused fields) + `cmd_len` bytes of command text +
    0..7 zero-padding bytes to align record_len to 8.
- `caps.decl` — new required cap: `KIND_PDXFS_FILE(write)` for
  history subtree writes.
- `design/architecture.md` — new §4b documenting the History module
  contract, wire format, error codes, and substrate deferral.

## Design decisions

### Wire format is the public contract

The HistoryEntry wire is what future readers (semantic-pipe consumers
of the history schema, `undo history clear` restore, cross-shell
history browsing at R56+) parse. Fixing it at M2 makes the M3+
substrate wiring a byte-append against a stable schema rather than a
joint format-and-plumbing exercise. The magic + record_len prefix
lets a corrupted or partially-written record be detected on read
(same discipline PdxFS v1 uses at its own leaf record layout).

### Three qword-sized fused fields

Each of the three header qwords is a single MOV to the wire:

- qword0: `magic | (record_len << 32)` — HIST_MAGIC in low 32,
  record_len in high 32.
- qword1: `ts_ns` — the caller-supplied timestamp (encoder does not
  mint a clock read of its own; clock reads live at the dispatch
  layer, per pds-format.md §2 delegation discipline).
- qword2: `cmd_len | (masked_flags << 32)` — cmd_len in low 32,
  flags masked to bits 0..1 in high 32.

A torn write between fields inside one record is impossible on
x86-64 (each qword store is atomic against a reader observing the
same qword). Cross-qword tearing is possible; a partial-write
detector at the reader can compare record_len against actual bytes
delivered.

### Flags masked at the encoder

Bits 2..31 of `flags` are silently cleared before the write. A
caller passing an unknown bit does not get an error but also does
not corrupt any reader (unknown bits read as zero after mask). This
matches libpdx-elevate's flag mask discipline
(`elevate_client_send.pdx` line 470: `and r10, 0xFF`) — the
encoder is the authoritative point where "known bits only" is
enforced, so a decoder needs no defensive masking.

### cmd_len == 0 is valid

An empty command represents "user pressed Enter on empty prompt".
This is a real event that D3 audit-first (from `r49-r50-plan.md`
§1) requires be journaled. The encoder allows cmd_len == 0 (with
cmd_ptr == 0 also allowed; the byte-copy loop is skipped
entirely). The record still has a 24-byte header + 0 padding = 24
bytes total.

### shr/shl for 8-alignment rounding

`record_len = (24 + cmd_len + 7) / 8 * 8` is computed as
`add rax, 7; shr rax, 3; shl rax, 3` — no 64-bit immediate mask
required. This is stricter than the paideia-as `cmp reg, imm ≤
0x7FFFFFFF` rule strictly requires (AND with imm32 sign-extends to
64 and is valid), but shifting is one instruction shorter and
avoids any large-immediate hop.

### KIND_PDXFS_FILE narrowed to history subtree

`caps.decl` gains `KIND_PDXFS_FILE(write)`. The runtime narrowing
at session start (a call to libpdx-cap's `cap_pack_narrowed` in
the shell's session-bootstrap path, not part of this landing) will
restrict the write cap to `~/.history/` specifically. Children
never receive this cap — history subtree writes are the shell's
own state, not a child's.

## paideia-as conformance checklist

- Module name PascalCase basename (`History`): yes.
- No `test` mnemonic: verified — every zero-check uses `cmp reg, 0`,
  every bound compare uses immediate ≤ 4096.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Large immediates: `HIST_MAGIC = 0x54534948` and return codes
  (`0xFFFFEC60..62`) emitted via `mov r10, imm32` / `mov rax, imm32`
  — same precedent as Session's `mov r10, 0x01940000`.
- `r11` used only in the singleton-write LEA (happy path only).
- Byte reads / writes use `xor rax, rax; mov_b rax, [ptr]` and
  `mov_b [ptr], rax` respectively in the byte-copy inner loop and
  the zero-pad loop — same #1248 pattern libpdx-cap's caps_decl
  parser uses.
- 5 pushes (rbx, r12, r13, r14, r15) + `sub rsp, 8` = 48 bytes
  prologue; rsp % 16 == 0 for shell_note. Matched epilogue at every
  return.

## What later milestones build on top

- M3 semantic-pipe: the shell emits a `HistoryEntry[]` schema record
  on request (per shell's declares_output_schemas — currently
  ShellPromptRecord, CommandCompletion, ShellCommandRecord;
  HistoryEntry will be added when the schema-registry work at M3-002
  formalises the shell's own output schemas).
- M3 PdxFS write: the exec dispatcher, after every line commit, calls
  `history_encode_record` to build the bytes and then
  `sys_ipc_send(svc.pdxfs-journal, bytes)` to append to
  `~/.history/<session>-<ts>.pdxhist`.
- M4 undo: `undo history clear` restores the file from the
  PdxFS v1 undo record whose replay is `pdxfs restore
  ~/.history/<session>-<ts>.pdxhist`.
