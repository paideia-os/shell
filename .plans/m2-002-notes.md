# shell.M2-002 — implementation notes

**Issue:** #5
**Status:** LANDED
**Landed by:** Fix #5

## What landed

- `src/pipeline.pdx` — `Pipeline` module:
  - `PL_CAP_ENTRY_SIZE = 16`, `PL_ENTRIES_PER_PIPE = 2`,
    `PL_MAX_STAGES = 8`, `PL_KIND_IPC_ENDPOINT = 5`.
  - `PL_STDIN_SLOT = 0`, `PL_STDOUT_SLOT = 1` (POSIX-analogous).
  - `PL_RIGHTS_READ = 0x1`, `PL_RIGHTS_WRITE = 0x2` (unidirectional).
  - Error band 0xFFFFEC4x: `PL_ERR_BAD_ARGS`, `PL_ERR_TOO_MANY`,
    `PL_ERR_DST_OVERFLOW`.
  - `.bss` singleton `pipeline_entries_written : u64`.
  - `pipeline_reset()` — zero the singleton.
  - `pipeline_plan(dst, stages_count, dst_max_entries, first_slot) →
    rc` — writes `2*(stages_count-1)` 16-byte Cap wire records for
    the pipeline's `|` operators. Writer entry: KIND=5, rights=WRITE,
    target_ptr=pipe_id, slot=PL_STDOUT_SLOT. Reader entry: KIND=5,
    rights=READ, target_ptr=pipe_id, slot=PL_STDIN_SLOT. The two
    entries per pipe share `target_ptr` so the loader-side validator
    can pair them.
- `design/architecture.md` — new §3b documenting the Pipeline module
  contract, sidecar layout, substrate deferral, and error codes.

## Design decisions

### Placeholder pipe ids at M2

The `target_ptr` field carries a small integer `p` (0, 1, 2, ...) at
M2 rather than a real endpoint id. Rationale: the endpoint mint
substrate is not wired in the shell repo at HEAD (2026-08-21 — same
substrate gap that made line_reader.pdx and exec.pdx M1 skeletons
return `LR_STUB` / `EX_STUB`). The M3 wiring will replace the
placeholder in one place — the loop body's `mov [r12 + r10 + 8], rbx`
line — after minting each endpoint via `sys_ipc_recv`. Every consumer
already writes into a well-defined slot in the sidecar; the M3 diff
is one instruction per entry.

Placeholder ids are internally-consistent: within one `pipeline_plan`
call, the two entries per pipe carry the same `target_ptr` value.
This is enough for the exec layer (M2-003) to pair the entries when
building per-child sub-sidecars.

### Unidirectional pipes at the constant level

The rights masks are `PL_RIGHTS_READ = 0x1` and `PL_RIGHTS_WRITE =
0x2`. There is no code path in this module that writes `0x3` for a
single endpoint — a child that would receive both bits would be able
to loopback its own output into its own input, which the loader-side
validator rejects anyway. Enforcing the invariant at the constant
level (never `or` the two masks) keeps the reject site at the loader,
not distributed across shell logic.

### Bare command is a valid pipeline

`stages_count == 1` returns `PL_OK` with `pipeline_entries_written =
0`. The consumer (the exec layer) treats a bare command the same as
a pipeline of length 1 — no pipes to splice, just an execve. Handling
this at the planner rather than requiring the caller to short-circuit
keeps the caller's control flow uniform (`if pipeline_plan(...) ==
PL_OK, walk the child list; if entries_written == 0, no pipe wiring
needed`).

### PL_MAX_STAGES = 8

A hard cap of 8 stages is generous for interactive shell use — `a |
b | c | d | e | f | g | h` is already at the edge of human
readability. Scripted pipelines from `.pds` files (M2-004) exceeding
this cap are rejected by the planner; the `.pds` script driver can
split them across intermediate temporary files. The cap fits `imm ≤
0x7FFFFFFF` by wide margin — no large-imm hop needed for the compare.

### 5 callee-save pushes

`rbx` (loop counter) + `r12` (dst) + `r13` (stages_count) + `r14`
(dst_max_entries) + `r15` (pipe_count cache) = 5 pushes. With the
return address that's 6 slots on the stack; `sub rsp, 8` brings rsp
% 16 to 0 for the nested `shell_note` call. Matched epilogue at
every ret. This is one more push than `line_reader_read_line` /
`exec_spawn_and_wait` because the loop needs a counter (`rbx`) plus
a cached count (`r15`) — both must survive `shell_note` on the
happy path.

## paideia-as conformance checklist

- Module name PascalCase basename (`Pipeline`): yes.
- No `test` mnemonic: verified — every zero-check uses `cmp reg, 0`
  or `cmp reg, 8` (PL_MAX_STAGES; fits imm ≤ 0x7FFFFFFF).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Large immediates (`0x00050000` KIND lane, `0x0000000100000000` /
  `0x0000000200000000` rights lanes, `0xFFFFEC40..0xFFFFEC42`
  return codes): emitted via `mov r10, imm64` — same precedent as
  Session `mov r10, 0x01940000`.
- `r11` used only in the two `lea r11, [rip + pipeline_entries_written]`
  slots (reset + happy-path count store).
- No byte reads.
- 5 pushes + `sub rsp, 8` prologue; matched epilogue at every return.

## What M2-003 builds on top

- `exec_narrow_child_caps` (M2-003) reads the flat entry sequence
  `pipeline_plan` writes and demuxes entries per child (writer
  entries → parent stage's sidecar; reader entries → child stage's
  sidecar).
- The per-child assignment logic — "entry 2p+0 goes to stage[p]'s
  sidecar; entry 2p+1 goes to stage[p+1]'s sidecar" — lives in the
  exec layer, not in the planner.
