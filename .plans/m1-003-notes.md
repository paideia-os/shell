# shell.M1-003 — implementation notes

**Issue:** #3
**Status:** LANDED
**Landed by:** Fix #3

## What landed

- `src/exec.pdx` — `Exec` module:
  - `exec_spawn_and_wait(argv, argv_count) → u64` — validates the
    caller's argv, bumps `SH_ST_SPAWNS` on entry, returns `EX_STUB`
    (0xFFFFEC20) on the happy path and `EX_ERR_BAD_ARGV` (0xFFFFEC21)
    with `SH_ST_ERRORS` bump on reject.

## Design decisions

### Why EX_STUB on the happy path

The design doc §5.2 M1 asks for "the smallest exec path
(`sh -c '/bin/echo hi'` finds /bin/echo in the InitCap-seeded
path, calls sys_execve, waits, prints exit code)". But the
substrate the M1 body needs is not yet available in the
paideia-os or paideia-as tree:

- **No userspace sys_execve wrapper.** The kernel side lands at
  R17 (`src/kernel/core/syscall/handlers/`), but a userspace
  binary calling it needs an assembly wrapper the shell repo
  will ship alongside the pipeline mint at M2. The wrapper is a
  small piece of work but it depends on libpdx-cap.M2 (cap
  narrowing at exec) and libpdx-argv.M2 (children's argv), both
  of which the design doc explicitly lists as M2 dependencies
  for shell.
- **No InitCap sidecar builder in userspace.** The 16-byte record
  wire format is shared with libpdx-cap (`src/cap.pdx`), but
  building an array of them for the child requires the M2 cap
  manifest verify to have landed.
- **No sys_wait4 userspace wrapper.** Same shape as sys_execve.

Manufacturing a spawn we did not actually perform would lie to
the shell's audit journal at M3 (`ShellCommandRecord via
libpdx-audit before sys_execve`). Skeleton is the only
principled option — same rationale as LineReader.

The M2 body replaces the EX_STUB tail with the real
sys_execve + sys_wait4 dispatch; every consumer already spells
`exec_spawn_and_wait` correctly at its call site.

### M2 call graph (documented, not built)

The header comment §"M2 CALL GRAPH" documents the seven-step
sequence: parse argv via libpdx-argv, resolve path against the
InitCap-seeded PATH cap set, build the InitCap sidecar (16-byte
records matching libpdx-cap's wire format), call
libpdx-cap::cap_manifest_verify to refuse a child that would
receive an undeclared cap, call sys_execve, block on sys_wait4,
print the exit code, return it. This is documentation work M1
does so M2 is a body edit rather than a design pass.

### Prologue shape

Identical to `line_reader_read_line`: two callee-save pushes
(r12 = argv, r13 = argv_count) + `sub rsp, 8` for SysV alignment
across the nested `shell_note` call. Same idiom as
`elevate_client_lookup_broker` in libpdx-elevate.

## paideia-as conformance checklist

- Module name PascalCase basename (`Exec`): yes.
- No `test` mnemonic: verified — the only compares are `cmp r12, 0`
  and `cmp r13, 0`, both use `cmp reg, 0` (small immediate).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Large-immediate stub sentinels (`0xFFFFEC20`, `0xFFFFEC21`) are
  `mov rax, imm32` emissions.
- `r11` scratch: not needed in this module.
- Byte reads: none in M1; the `xor rax, rax; mov_b rax, [ptr]`
  pattern lands at M2 with the argv walker.
- Two callee-save pushes (r12 + r13) with matched pops on every
  return path.

## What M2 builds on top

- Replace the EX_STUB tail with:
  ```
  call libpdx_argv_parse            # (path, argv_ptrs, argv_len)
  call libpdx_argv_resolve_path     # against InitCap-seeded PATH
  call build_initcap_sidecar        # narrow each cap per callee's caps.decl
  call cap_manifest_verify          # refuse undeclared caps
  call sys_execve
  # -> pid
  call sys_wait4
  # -> wstatus
  and rax, 0xFF
  # -> exit code
  ```
- Add `EX_ERR_EXECVE_FAIL` / `EX_ERR_WAIT_FAIL` paths.
- Add `SH_ST_EXITS` bump on successful wait return.
- Pipeline shape at M2-002: pair of `exec_spawn_and_wait` calls
  sharing a minted KIND_IPC_ENDPOINT for stdin/stdout splice.
