# shell.M1-001 — implementation notes

**Issue:** #1
**Status:** LANDED
**Landed by:** Fix #1

## What landed

- `src/shell.pdx` — `Shell` module:
  - KIND ordinal mirrors (`SH_KIND_USER = 0x190`,
    `SH_KIND_IPC_ENDPOINT = 5`, `SH_KIND_ELEVATE_CHANNEL = 0x191`,
    `SH_KIND_SHELL_SESSION = 0x194`, `SH_KIND_PDXFS_FILE = 0x195`,
    `SH_KIND_TTY = 0x196` provisional).
  - Return-code band `0xFFFFECxx` (SH_OK, LR_STUB, LR_ERR_BAD_BUF,
    LR_ERR_TTY_UNBOUND, LR_ERR_EOF, EX_STUB, EX_ERR_BAD_ARGV,
    EX_ERR_EXECVE_FAIL, EX_ERR_WAIT_FAIL).
  - `.bss` singleton `_shell_stats : [u64; 8]` cache-line aligned.
  - `shell_reset()` — zero the eight-slot table.
  - `shell_note(which)` — bounded increment; out-of-range is a no-op.
  - `shell_stat(which)` — bounded read; out-of-range returns 0.
- `caps.decl` — shell requires KIND_USER(read), KIND_TTY(write),
  KIND_IPC_ENDPOINT(mint), KIND_SHELL_SESSION(mint); declares
  ShellPromptRecord, CommandCompletion, ShellCommandRecord.
- `design/architecture.md` — full M1 spec covering all three
  modules (§2 Shell / §3 LineReader / §4 Exec), §5 return-code
  band, §6 paideia-as conformance, §7 M4 test matrix.
- `README.md`, `STATUS.md` — refreshed for M1 complete.
- `tests/README.md` — M4-deferred placeholder.

## Design decisions

### KIND ordinal mirrors

The shell's Shell module owns numeric aliases for every KIND the
shell touches, even though libpdx-cap already owns the wire
vocabulary. Rationale: the shell repo is a separate binary that
does not necessarily link the paideia-os kernel `.o` graph at
build time — same rationale libpdx-elevate documents for
mirroring `ELV_*` (see libpdx-elevate/src/elevate_request.pdx
§"WHY REDECLARE THE WIRE CONSTANTS"). The `SH_` prefix marks
these as mirrors; any drift from the authoritative kernel values
is caught at M4 by the smoke matrix.

`SH_KIND_TTY = 0x196` is provisional. `kind_tty.pdx` does not
exist in `src/kernel/core/cap/` at HEAD (2026-08-21). The shell's
caps.decl names KIND_TTY symbolically (libpdx-cap's parser is
textual), and the M2 InitCap sidecar builder stamps this constant
into the wire record. Softarch pins the real ordinal when the
KIND_TTY substrate PR lands.

### Return-code band

The `0xFFFFECxx` band is disjoint from every other layer's band:

- libpdx-cap owns `0xFFFFFFxx` (`CAP_BAD_SLOT` etc.).
- libpdx-elevate owns `0xFFFFEAxx` (client) and `0xFFFFE5Exx`
  (wire).
- kernel errno owns `0xFFFFFFFFFFFFFFxx` (two's-complement -EFAULT
  etc.).

A downstream consumer can look at the high two bytes of a return
and know which layer refused. Same discipline as the R48.M7
elevate protocol.

### Stats table

Eight slots, cache-line aligned, with `_shell_stats` in `.bss`.
Same shape as `ElevateBroker._elevate_broker_stats` (paideia-os
`src/kernel/core/ipc/elevate_broker.pdx:70`) and
`_elevate_client_stats` (libpdx-elevate `src/elevate_client.pdx`).
`shell_note` / `shell_stat` are bounded so an out-of-range slot
is a no-op or returns 0 — a caller passing a slot from a newer
snapshot cannot corrupt live counters.

## paideia-as conformance checklist

- Module name PascalCase basename (`Shell`): yes.
- No `test` mnemonic: verified — the only compares are `cmp rcx, 8`
  (loop bound in `shell_reset`) and `cmp rdi, 8` (bounds check
  in `shell_note` / `shell_stat`). Both use small immediates.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes — largest is
  `cmp rdi, 8`.
- Large-immediate return codes (`0xFFFFEC10` etc.) are `mov rax,
  imm32` emissions, same precedent as libpdx-cap's `CAP_BAD_SLOT`
  and libpdx-elevate's `ELVC_STUB`.
- `r11` scratch: not needed in this module (no `.bss` reach uses
  it — `r10` addresses `_shell_stats` directly).
- Byte reads: none in this module.
- Leaf functions with no push/pop parity: yes — `shell_reset`,
  `shell_note`, and `shell_stat` are all leaves.

## What M2 builds on top

- Session-lifetime `_start` frame calls `shell_reset` once at boot,
  then enters the LineReader → Exec loop.
- `SH_KIND_SHELL_SESSION` mint at session start (M2-001).
- `SH_KIND_IPC_ENDPOINT` mint per `|` (M2-002).
- Stats table adds slots 5..7 for pipeline / session / audit
  counters as those substrates land.
