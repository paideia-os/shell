# shell.M2-004 — implementation notes

**Issue:** #7
**Status:** LANDED
**Landed by:** Fix #7

## What landed

- `src/pds.pdx` — `Pds` module:
  - Limits: `PDS_MAX_CAPS = 16`, `PDS_MAX_IMPORTS = 8`,
    `PDS_MAX_SCHEMAS = 8`.
  - Error band 0xFFFFEC5x: `PDS_ERR_BAD_ARGS` (0xFFFFEC50),
    `PDS_ERR_MALFORMED` (0xFFFFEC51), `PDS_ERR_OVERFLOW`
    (0xFFFFEC52).
  - `.bss` singleton (6 slots): `pds_has_shebang`, `pds_ascii_flag`,
    `pds_capability_count`, `pds_import_count`, `pds_schema_count`,
    `pds_body_offset`.
  - `pds_reset()` — zero the six singleton slots.
  - `pds_parse(buf, buf_len) → rc` — line-oriented byte walker that
    consumes the header pragma block, dispatches by second-byte
    lookahead (`!`, `c`, `i`, `s`, `r`, `a`), tracks counts + flags,
    and returns `pds_body_offset` = the byte offset in `buf` where
    the body starts.
- `design/architecture.md` — new §4a documenting the Pds module
  contract, dispatch table, and body-dispatch responsibility split.

## Design decisions

### Header-only parse; body handled elsewhere

The parser reads the header pragma block and stops at the first
non-`#` line (or blank line). The BODY is shell pipeline syntax
per `semantic-shell.md` §2, and it is handled by the same
`pipeline_plan` + `exec_narrow_child_caps` path a live interactive
line would take. This split matches `pds-format.md` §2's own
delegation of body semantics to the shell's main grammar and keeps
this module scoped to the (small) manifest-like parsing job.

### Second-byte lookahead

For the M2 pragma set, the second byte after `#` uniquely
identifies the pragma: `#!`, `#capability`, `#import`, `#schema`,
`#requires-paideia`, `#ascii`. Dispatching on the second byte alone
keeps the parser compact and every compare is `cmp reg, imm ≤
0x7FFFFFFF`. If M3 adds a second `#c*` or `#i*` pragma, the
dispatch will need a longer prefix compare — but the current spec
does not, and preemptively longer compares would carry more error
surface than value.

### Counts, not string values

`pds_capability_count = 3` says the script has 3 `#capability`
pragmas; the strings themselves are re-read by the exec dispatcher
at capability-narrowing time from the caller-owned buffer. This
halves the RAM cost of a script's header versus a copy-out model
and matches libpdx-cap's caps_decl parser (which does materialise
strings — but the two parsers have different consumers: caps.decl
strings are consumed once per exec by the manifest_verify path,
while pds header strings are consumed once per script by the
exec dispatcher; both patterns are reasonable at their consumer
count).

If M3 introduces `#import path resolution` as a first-class
operation (loading the imported file via PdxFS), the parser can
be extended with `(offset, length)` pairs — mirrors libpdx-argv's
flag_names discipline. Deferring that until it is needed keeps
this M2 landing minimal.

### `#requires-paideia` is recorded implicitly

The paideia-os kernel does not expose a runtime-queryable version at
HEAD (2026-08-21). Enforcing `#requires-paideia ≥ 0.5` requires
the kernel side that landing depends on the R42 kernel-info
substrate, which is a post-R49 concern. The parser recognises the
pragma (matches on the `r` byte) and skips its line without
incrementing any count — the intent is preserved (the line is
valid and does not fail), but no enforcement happens at M2.

### Blank line ends header

`pds-format.md` §1 does not explicitly authorise blank lines within
the pragma block. The parser treats the first blank line as a
header terminator (same rule as HTTP headers). A script that wants
comments between pragmas can use `#` lines that are not recognised
pragmas — but the current parser rejects those with
`PDS_ERR_MALFORMED`. If real-world scripts need blank-line
tolerance, that is an M3 spec extension, not a code change here.

### rbx as "any-pragma-consumed" flag

The parser sets `rbx = 1` after ANY pragma has been consumed (not
just shebang). This lets the shebang check `cmp rbx, 0` reject a
stray `#!` line later in the header (shebang is FIRST-LINE ONLY per
convention). One flag serves both the shebang-first check and the
header-line-count observation.

## paideia-as conformance checklist

- Module name PascalCase basename (`Pds`): yes.
- No `test` mnemonic: verified — every zero-check uses `cmp reg, 0`,
  every bound compare uses immediate ≤ 16.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes.
- Byte reads use `xor rax, rax; mov_b rax, [ptr]` pattern per #1248:
  yes — every byte load in the line-head dispatch and the second-
  byte lookahead follows the pattern; the skip-to-EOL loop also.
- `r11` reserved as .bss LEA scratch for pds_* singleton addresses.
- 3 pushes (rbx, r12, r13) + `sub rsp, 8` = 32 bytes prologue; rsp
  % 16 == 0 for shell_note. Matched epilogue at every return.

## What later milestones build on top

- M3 `.pds` exec: the driver calls `pds_parse` first, then walks the
  body bytes from `pds_body_offset` through the interactive line
  reader path, dispatching each pipeline through
  `pipeline_plan + exec_narrow_child_caps`.
- M3 `#capability` enforcement: the driver reads the caps.decl
  strings from the script buffer using the count from
  `pds_capability_count`, converts each to a KIND requirement, and
  hands it to `exec_narrow_child_caps` as the child_decl for the
  scripted pipeline.
