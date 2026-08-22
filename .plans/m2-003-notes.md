# shell.M2-003 — implementation notes

**Issue:** #6
**Status:** LANDED
**Landed by:** Fix #6

## What landed

- `src/exec.pdx` — new entry point `exec_narrow_child_caps` (M2-003
  section added; existing `exec_spawn_and_wait` M1 skeleton unchanged).
  - `EX_NARROW_MAX_ENTRIES = 16` (cap on parent/child_decl array sizes).
  - Signature: `(parent, parent_count, child_decl, child_decl_count,
    dst, dst_max_entries) → rc`.
  - Body: for each child_decl entry, linear-scan parent for matching
    KIND, widen-check `(child_rights & ~parent_rights) == 0`, write
    narrowed Cap with `rights = child & parent`, `target_ptr =
    parent's target_ptr`.
  - Error paths reuse M1's `EX_ERR_BAD_ARGV` (0xFFFFEC21) for null-
    ptr / count-zero + new codes: `EX_ERR_MISSING_CAP` (0xFFFFEC24),
    `EX_ERR_WIDENING` (0xFFFFEC25), `EX_ERR_SIDECAR_FULL`
    (0xFFFFEC26).
- `design/architecture.md` — new §4.2b documenting the narrowing
  contract, its interaction with M2-001 (session cap) and M2-002
  (pipeline caps), and why `exec_spawn_and_wait` remains at
  `EX_STUB` at M2 (substrate deferral unchanged).

## Design decisions

### Narrowing invariants — enforced by construction

Two invariants the narrowing must maintain simultaneously:

- **MONOTONE.** The child's rights are a strict subset of the
  parent's. Widen check `(child & ~parent) == 0` — same predicate
  libpdx-cap's `cap_pack_narrowed` uses at its byte-level analogue.
  Refused with `EX_ERR_WIDENING`.

- **NARROWED.** The child's actual rights are `child & parent` —
  the intersection, not the union. A child that requests
  `KIND_TTY(read)` when the parent holds `KIND_TTY(write)` gets
  nothing (widening check catches this before intersection: read is
  in child but not parent, refused as widening). A child that
  requests `KIND_PDXFS_FILE(read)` when the parent holds `read |
  write` gets read only.

Refusal on either invariant leaves `dst` in a poisoned state
(partial results possibly written for earlier entries). This matches
libpdx-cap `cap_manifest_verify`'s discipline: caller treats the
buffer as invalid on any non-OK return. The alternative
(rollback-on-error) would need a second pass through `dst`, which
buys nothing when the caller's exec path aborts on error anyway.

### target_ptr comes from parent, not decl

The narrowed Cap's `target_ptr` is copied from the PARENT'S entry,
not from the child's decl entry. Rationale: the child's decl says
what KIND + rights the child wants; the parent's cap says what
target the KIND actually addresses. A decl that invented its own
target would let a child request access to a file the parent does
not own — which the loader-side validator would reject anyway, but
enforcing it here means the reject site is the exec layer (where
the diagnostic is available) rather than deep in the loader.

### child_decl_count == 0 is valid

A child that declares no caps beyond the ambient session (which is
added by M2-001 outside this helper) returns `EX_OK` with `dst`
untouched. This is the common case for `mkdir` (only needs the
session cap and a PdxFS write cap that the shell already knows to
add). The helper does not force the caller to guard the empty case
before calling.

### Six callee-save pushes

`rbx` (outer i) + `rbp` (dst cache) + `r12` (parent) + `r13`
(parent_count) + `r14` (child_decl) + `r15` (child_decl_count) = 6.
With the return address that's 7 slots; `sub rsp, 8` brings rsp %
16 to 0 for `shell_note`. Matched epilogue at every ret. Same
6-push idiom as libpdx-argv `parse_argv`.

### exec_spawn_and_wait remains EX_STUB

`exec_spawn_and_wait` (M1-003) is NOT modified at M2-003. The
sys_execve syscall wrapper still isn't landed at HEAD; the M2-003
narrowing helper is a pure buffer operation invoked separately by
the exec dispatcher. When M3 substrate lands, `exec_spawn_and_wait`
will call `exec_narrow_child_caps` before dispatching sys_execve,
but that wiring is M3's scope, not M2's.

## paideia-as conformance checklist

- Module scope: `Exec` (unchanged; added a second entry point).
- No `test` mnemonic: verified — every zero-check uses `cmp reg, 0`;
  every bound compare uses immediate ≤ 16 (`EX_NARROW_MAX_ENTRIES`).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Large immediates (`0xFFFF` mask, `0xFFFFEC21..0xFFFFEC26` return
  codes): mask fits imm32; return codes emitted as `mov rax, imm32`
  (same precedent as libpdx-cap's `mov rax, 0xFFFFFFFE`).
- `r11` scratch: used only for the inner-scan cursor (register-only,
  no `lea r11, [rip + sym]` because this helper has no `.bss`
  reach — everything is caller-owned buffers).
- No byte reads (all fields are qword-loads from wire records).
- 6 pushes + `sub rsp, 8`; matched epilogue at every return.

## What M2-004 builds on top

- `pds_parse` (M2-004) produces a header record describing what
  caps + imports a `.pds` script requires. The script driver
  combines these with the shell's own held caps and calls
  `exec_narrow_child_caps` once per script-spawned child.

## What M3 builds on top

- The exec dispatcher (M3+) invokes, in order:
  1. `session_derive_subcap` → 1 sidecar entry (session cap).
  2. `pipeline_plan` per-child slice → 0..2 sidecar entries per
     child (stdin + stdout pipe caps if the child is in a pipeline).
  3. `exec_narrow_child_caps` → up to 16 sidecar entries (ambient
     caps.decl narrowed against parent).
- Then concatenates the three buffers and hands the sidecar to
  `sys_execve` as the child's initial cap set.
