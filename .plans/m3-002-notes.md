# shell.M3-002 — implementation notes

**Issue:** #10
**Status:** LANDED
**Landed by:** Fix #10

## What landed

- `src/completion.pdx` — `Completion` module:
  - Constants: `COMP_HEADER_SIZE = 16`, `COMP_NAME_MAX = 512`,
    `COMP_SCORE_MAX = 1000`, `COMP_MAGIC = 0x504d4f43`
    (little-endian "COMP").
  - Kind vocabulary: `COMP_KIND_COMMAND = 1` .. `COMP_KIND_SCHEMA
    = 5`; `COMP_KIND_MAX = 5` for bound checks.
  - Error band 0xFFFFEC8x: `COMP_ERR_BAD_ARGS` (0xFFFFEC80),
    `COMP_ERR_TOO_LONG` (0xFFFFEC81), `COMP_ERR_TRUNCATED`
    (0xFFFFEC82), `COMP_ERR_EMPTY_NAME` (0xFFFFEC83).
  - `.bss` singleton `completion_bytes_written : u64`.
  - `completion_reset()` — zero the singleton.
  - `completion_encode_record(dst, dst_len, name_ptr, name_len,
    kind, score) → rc` — serialise one CommandCompletion record:
    16-byte header (two qword-fused fields) + `name_len` UTF-8
    bytes + 0..7 zero-padding bytes to align record_len to 8.
- `src/shell.pdx` — new counter `SH_ST_COMPLETIONS = 9` (stats
  table already widened to 16 by M3-001).
- `design/architecture.md` — new §4d documenting the Completion
  module contract, wire format, kind vocabulary, and error codes.

## Design decisions

### CommandCompletion is SH-D7's typed candidate

Per SH-D7 in `design/terminal/semantic-shell.md`, tab-completion
is schema-registry-driven: the candidate is a typed record
naming (kind, name, score) so a downstream renderer can style
commands vs. files vs. options vs. schema hits differently, and
so a semantic-pipe consumer (query, pipeviz) can filter by kind
without column-slicing text. The wire format bakes this in at the
schema level.

### Two-qword fused header

- qword0: `magic | (record_len << 32)` — 32-bit magic in low half,
  32-bit record_len in high half. Same pattern as History's
  qword0.
- qword1: `kind | (score << 16) | (name_len << 32)` — kind (u16)
  + score (u16) + name_len (u32) fused into one atomic write.
  Kind and score fit u16 by construction; name_len fits u32 by
  the COMP_NAME_MAX ≤ 512 bound.

Each qword is one MOV to the wire — a torn write between fields
inside one header is impossible on x86-64.

### Kind vocabulary closed at M3

Adding a kind is a schema-version bump. Reserved values (0 and
6..65535) fall back to plain-text rendering at the downstream
renderer. This keeps the wire stable for the M4+ consumer without
requiring a shared enum-registry file the shell and the reader
would both have to link.

### Empty candidate refused

An empty candidate name (`name_len == 0`) is refused as a distinct
error code (`COMP_ERR_EMPTY_NAME`, 0xFFFFEC83). Reason: the empty
string is not a legitimate completion candidate; if the ranker
emits one, it's a caller-side bug (produced an empty candidate
during the schema walk). Distinct code from BAD_ARGS so the
diagnostic is unambiguous.

### Score ceiling 1000, not 100 or 65535

Scores in 0..1000 give the ranker enough resolution to
differentiate (e.g.) exact prefix match (900) from fuzzy match
(500) from substring match (300). Ceiling of 1000 fits comfortably
in u16 (< 65536) and matches the paideia-as `cmp reg, imm ≤
0x7FFFFFFF` rule. A caller passing score > 1000 gets BAD_ARGS
because a higher score would mis-sort the downstream renderer's
ordered list against records the ranker produced within the
0..1000 range.

### shr/shl for 8-alignment

Same as History: `record_len = (16 + name_len + 7) / 8 * 8` uses
`add rax, 7; shr rax, 3; shl rax, 3` — no large-immediate mask
needed.

## paideia-as conformance checklist

- Module name PascalCase basename (`Completion`): yes.
- No `test` mnemonic: verified — every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes; the largest
  is COMP_NAME_MAX (512) and COMP_SCORE_MAX (1000), both
  compared as small immediates.
- Large immediates (`COMP_MAGIC = 0x504d4f43`, error codes
  `0xFFFFEC80..83`) via `mov r10, imm32` / `mov rax, imm32`.
- `r11` used only in the singleton-write LEA on the happy path.
- Byte reads / writes use `xor rax, rax; mov_b rax, [ptr]` and
  `mov_b [ptr], rax` in the name-copy inner loop and the zero-pad
  loop.
- 5 pushes (rbx, r12, r13, r14, r15) + `sub rsp, 8` = 48 bytes
  prologue; rsp % 16 == 0 for shell_note. Matched epilogue.

## What later milestones build on top

- M4 tab-completion driver: the line_reader's TAB key binding
  triggers a schema-registry walk. For each match, the driver
  scores against the partial input, then calls
  `completion_encode_record` and appends the bytes to the
  ShellPromptRecord response.
- M4 semantic-pipe emit: the encoded records go out over the
  shell's schema pipe (via libpdx-semantic-pipe's frame builder)
  as a `CommandCompletion[]` response.
- R51+ schema-typed completion: when `query` and `less` land, the
  ranker will expose a way for external tools to contribute
  candidates via the same schema. The M3 encoder is the ground
  truth for that wire.
