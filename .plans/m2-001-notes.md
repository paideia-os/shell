# shell.M2-001 — implementation notes

**Issue:** #4
**Status:** LANDED
**Landed by:** Fix #4

## What landed

- `src/session.pdx` — `Session` module:
  - `SS_KIND = 0x194` (KIND_SHELL_SESSION ordinal mirror).
  - `SS_CAP_ENTRY_SIZE = 16`, `SS_SLOT_MAX = 256` — matches libpdx-cap
    format constants.
  - Rights masks: `SS_RIGHTS_READ = 0x1`, `SS_RIGHTS_WRITE = 0x2`,
    `SS_RIGHTS_MINT = 0x4`, `SS_RIGHTS_ALL = 0x7`, `SS_RIGHTS_CHILD = 0x3`.
  - Error band 0xFFFFEC3x: `SS_ERR_BAD_DST`, `SS_ERR_BAD_ID`,
    `SS_ERR_BAD_SLOT`.
  - `session_mint(dst, slot, session_id) → rc` — writes the shell's
    root KIND_SHELL_SESSION Cap with SS_RIGHTS_ALL rights (mint bit
    set so this shell can derive sub-caps).
  - `session_derive_subcap(dst, slot, parent_session_id) → rc` —
    writes a child KIND_SHELL_SESSION Cap with SS_RIGHTS_CHILD rights
    (mint bit CLEARED at the constant level; strict-monotone-narrowing
    invariant enforced by construction).
- `src/shell.pdx` — new stat slots: `SH_ST_SESSIONS = 5`,
  `SH_ST_PIPELINES = 6`, `SH_ST_HISTORY = 7`. Slot 4 (`SH_ST_ERRORS`)
  and slots 0..3 unchanged.
- `design/architecture.md` — new §3a documenting the Session module
  contract, rights masks, error codes, and its interaction with the
  InitCap sidecar. §5 error-band table extended for the full 0xFFFFECxx
  M2 allocations (SS_*, PL_*, EX_*, PDS_*, HIST_*).

## Design decisions

### Wire layout — one format for every Cap

The 16-byte record shape (qword0 = slot | (kind << 16) | (rights << 32),
qword1 = target_ptr) is the same layout libpdx-cap's `Cap` and
paideia-os's InitCap sidecar validator both agree on. The shell does
NOT link libpdx-cap for this module — the wire format is the public
contract everyone shares, and re-implementing the format writer here
keeps the module self-contained while making cross-repo linkage a
separate M3+ concern.

Why not link libpdx-cap now? Because the M1 discipline was "no
external symbol references from the shell repo"; the shell's own
build artefact at M2 is still standalone. The pack path here is 8
lines of assembly (three qword compares + a two-qword store); the
linkage complexity would exceed the code savings. When M3 lands
cross-repo linkage for the semantic-pipe / audit path, the two-qword
store here can be swapped for a `call cap_pack_narrowed` — every
consumer already writes 16 bytes into the caller's buffer.

### Rights narrowing — enforced at the constant

`session_mint` writes `SS_RIGHTS_ALL = 0x7`. `session_derive_subcap`
writes `SS_RIGHTS_CHILD = 0x3`. There is no code path in this module
that writes any other rights mask — the strict-monotone-narrowing
invariant is enforced at the constant level, not by a runtime check.
This is the same "impossible to widen through this entry point"
discipline libpdx-cap uses in `cap_pack_narrowed`: the widen check
runs against the caller's inputs, but any inputs derived from
`session_mint`'s output can only shrink.

The child inherits its parent's session_id (target_ptr), so audit-
journal readers can correlate every stage of a pipeline as one
work-unit. This binds the audit correlation to the wire format
rather than to a runtime table.

### Fail-fast — reject leaves dst untouched

Every gate (`cmp r12, 0` for dst; `cmp r14, 0` for session_id;
`cmp r13, 256` for slot) precedes any store to dst. A rejected mint
leaves the caller's buffer with its old contents, matching libpdx-cap
`cap_pack`'s `CAP_BAD_SLOT` discipline and paideia-os
`init_caps_validate`'s `INIT_CAPS_BAD_COUNT` precedent. This means a
caller that reuses one buffer across a mint attempt and a fallback
can distinguish "the previous mint's residue" from "this mint's
output" by inspecting the return code alone.

## paideia-as conformance checklist

- Module name PascalCase basename (`Session`): yes.
- No `test` mnemonic: verified — every zero-check uses `cmp reg, 0`
  or `cmp reg, 256` (fits imm ≤ 0x7FFFFFFF).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes (largest is 256).
- Large immediates (`0x01940000` for KIND lane, `0x0000000700000000`
  for rights lane, `0xFFFFEC30..0xFFFFEC32` for return codes): all
  emitted as `mov r10, imm64` — the assembler's canonical path, same
  precedent as libpdx-cap's `mov rax, 0xFFFFFFFE` (CAP_BAD_SLOT) and
  libpdx-elevate's `mov rax, 0xFFFFEA00` (ELVC_STUB).
- `r11` reserved as .bss LEA scratch: not needed in this module (no
  .bss reach). `r10` used for lane masks and large-imm constants.
- No byte reads.
- Two nested `call shell_note` sites per entry point; three callee-save
  pushes (r12, r13, r14) + `sub rsp, 8` = 32 bytes of prologue; the
  sub aligns rsp % 16 == 0 for the SysV call. Matched epilogue at every
  return. Same idiom as `elevate_client_lookup_broker` in libpdx-elevate.

## What M2-002 builds on top

- `pipeline_plan` (M2-002) will call `session_derive_subcap` once per
  child stage to produce the child's KIND_SHELL_SESSION entry in the
  InitCap sidecar buffer alongside the pipe endpoint Caps.
- `exec_narrow_child_caps` (M2-003) will emit the same session subcap
  as the FIRST entry in every child's sidecar (slot 0 by convention),
  so a child that receives no other caps still knows its session.
