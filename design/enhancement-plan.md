# shell — enhancement plan (post-v1.0.0)

**Status:** authored 2026-08-25, combined osarch+softarch audit pass.
**Milestone:** `v2.0 — real exec substrate` (see §6 for why not `v0.2`).
**Companion decision (already made, not re-litigated here):**
`design/roadmap/rows-4-5-6-scoping.md` §4.2 in the `paideia-os` monorepo.

---

## §1. Current state, stated bluntly

**`shell` cannot execute a command. It cannot read a line. It has never
run.** At `v1.0.0` this repository is a suite of twelve wire-format
encoders and pure bitmask narrowers over caller-owned buffers. It is not
an interactive shell, and no code path in it becomes one.

The measurements below are grep-verified against the tree at commit
`8106269`, not inferred from documentation:

| Claim | Evidence |
|---|---|
| Zero syscalls anywhere in `src/` | `grep -rE '^\s+syscall' src/` → 0 hits. The four textual `syscall` matches (`exec.pdx:17,34`, `pipeline.pdx:24`, `command_record.pdx:34`) are all inside comment blocks. |
| Zero cross-repo library calls | `grep -rE '^\s+call +(cap_\|audit_\|sp_\|argv_\|elevate_)' src/` → 0 hits. |
| Exactly one distinct call instruction in the whole repo | 60 `call` instructions across 11 files; all 60 are `call shell_note;` — a `.bss` counter bump. Every other `call ...` string in `src/` is prose inside a comment. |
| No lexer / tokenizer | No file, symbol, or `.bss` slot in `src/` splits a byte string on whitespace. `src/pds.pdx` parses a `.pds` *header* (shebang + `#`-pragma lines) and explicitly does not materialise string values (`design/architecture.md` §4a.4); it never sees a command line. |
| No parser / AST | `pipeline_plan(dst, dst_max_entries, stages_count, base_pipe_id)` (`src/pipeline.pdx:236`) takes a **pre-counted integer** `stages_count`. Nothing in the repo derives that integer from text. |
| No builtin dispatch table | No `builtin` symbol in `src/`, `caps.decl`, or `design/architecture.md`. No `cd`, `pwd`, `export`, or `exit` handler exists. The `exit` in `doc/shell.pdxdoc`'s example session has no dispatch site. |
| No exec path | `exec_spawn_and_wait` (`src/exec.pdx:432`) gates `argv != 0` and `argv_count != 0`, bumps two counters, and returns `EX_STUB = 0xFFFFEC20` (`src/exec.pdx:459`). |
| No line reader | `line_reader_read_line` (`src/line_reader.pdx:122`) gates the buffer and returns `LR_STUB = 0xFFFFEC10` (`src/line_reader.pdx:150`). |
| History never reaches disk | `history_encode_record` produces bytes; nothing writes them. |
| Broker bind never sends | `broker_bind_login_shell` returns `BB_STUB = 0xFFFFECB0` (`src/broker_bind.pdx:352`). |
| **The declared entry symbol does not exist** | `manifest.pdxproj:22` declares `entry = Shell::shell_main`. `module Shell` (`src/shell.pdx:63`) exports `shell_reset`, `shell_note`, `shell_stat` and 22 constants. There is no `shell_main` anywhere in the repository. |

That last row is the sharpest one. The build manifest names an entry
point that has never been written. Whatever `tools/build.sh` currently
produces, it is not a binary that can be entered.

### 1.1 What *does* exist, and is genuinely good

This is not a hollow repo. The encoder half is real, disciplined, and
golden-tested, and none of it needs rewriting:

- **`Shell`** (`src/shell.pdx`) — KIND ordinal mirrors, the `0xFFFFECxx`
  return-code band, a 16-slot cache-line-aligned `_shell_stats` table
  with `shell_reset` / `shell_note` / `shell_stat`. Works.
- **`Session`** (`src/session.pdx`) — `session_mint` (`SS_RIGHTS_ALL =
  0x7`) + `session_derive_subcap` (`SS_RIGHTS_CHILD = 0x3`, no `MINT`).
  16-byte Cap wire records. Strict-monotone narrowing enforced at the
  constant. Pure, correct, and reusable as-is.
- **`Exec::exec_narrow_child_caps`** (`src/exec.pdx:205`) — the widening
  check `(child & ~parent) == 0` plus rights intersection. This is the
  security core of the design and it is finished; only its *caller* is
  missing.
- **`Pipeline::pipeline_plan`** — emits `2*(N-1)` paired Cap records for
  an N-stage pipeline. Correct given a stage count.
- **`Pds`** — `.pds` header parser (shebang, `#capability`,
  `#requires-paideia`, `#import`, `#schema`, `#ascii`), six-slot `.bss`
  singleton, body offset. Correct for what it claims.
- **`History` / `Completion` / `CommandRecord` / `PipePassthrough` /
  `ReleaseManifest` / `BrokerBind`** — six frozen wire formats, every
  one fail-fast-gated, every one with `dst` untouched on reject.
- **Four test modules** (`tcn_run_all`, `taf_run_all`, `tsm_run_all`,
  `trm_run_all`) — 26 encoder-golden cases with hand-derived expected
  bytes pinned in-source.

The correct summary is: **`shell` v1.0.0 is a finished wire-format
library that has been packaged and tagged as a finished program.** The
plan below does not touch the library. It builds the program that was
never built.

---

## §2. What the kernel now provides that it did not at ship time

Every `STUB` in this repo carries a justification of the form "the
substrate does not exist yet." Those justifications were true on
2026-08-21. Most are false now. The stub era is over; what remains is
wiring.

| Substrate the repo defers to | State at v1.0.0 (repo's own claim) | State at HEAD (2026-08-25, verified) |
|---|---|---|
| `KIND_TTY` | "not landed; `kind_tty.pdx` does not exist" (`STATUS.md:309`) | **Exists** — `src/kernel/core/cap/kind_tty.pdx` (KIND_TTY = 0x197), with `TTY_OP_READ` (ordinal 6, gated by R_TTY_READ 0x080) + raw/cooked toggle now landed via paideia-os#1986 (R66v2.POS-001, CLOSED 2026-08-31). Two upstream landings still block a shell-side migration to a cap-typed read: KIND_TTY is absent from `KIND_SEEDABLE_TABLE` (`kind.pdx:3450`), and no shell-time TTY row seed at boot exists — see `design/architecture.md` §3.3 (refreshed at #46) for the ledger. |
| `sys_execve` with real argv/envp | "kernel side lands at R17" (`STATUS.md:317`) | **Exists** — `src/kernel/core/syscall/handlers/sys_execve_shim.pdx`; ABI frozen at `design/user/execve-abi.md` (argc in `rdi`, argv in `rsi` at `_start`); real argv/envp marshalling landed at **R62**. |
| `sys_wait4` | deferred | **Exists** — `src/kernel/core/syscall/handlers/sys_wait.pdx`. |
| `sys_chdir` / `sys_getcwd` | not contemplated | **Exist** — sysno 85 / 86, landed at **R86.M1-006/007** (paideia-os #1959/#1960); the monorepo's `cd_builtin` already calls `sys_chdir` directly (`src/user/dispatch.pdx:27`). |
| PdxFS write path | deferred (`STATUS.md:324`) | **Exists** — `KIND_PDXFS_FILE` write landed. |
| Byte-source for a line reader | blocked on `KIND_TTY(read)` | **Available today** via the VFS path: the monorepo's `shell_read_line` reads with `sys_read(0, ptr, 1)` byte-at-a-time and works in the live boot. |

**Consequence for framing.** The shell's stub state is no longer a
"waiting on the kernel" problem. It is a "wire up what the kernel
already shipped" problem, and it has been that for several rounds
without anyone noticing, because the repo's `STATUS.md` still describes
a 2026-08-21 kernel. The single genuine remaining kernel dependency is
the `KIND_TTY` read op — paideia-os#1986 landed the op itself, but
the shell-side seam swap remains blocked on two follow-up upstream
landings (KIND_TTY loader-seedability + shell-time TTY row seed at
boot). The VFS `sys_read` fallback continues to unblock the line
reader immediately (§4, ENH-007); see `design/architecture.md`
§3.3 (refreshed at #46) for the ledger.

---

## §3. What the monorepo shell already proves is achievable

`src/user/shell.pdx` in the monorepo is 152 lines and **does everything
this repo does not**: prompt, `shell_read_line` (byte-at-a-time until
`\n`/EOF/full), `tokenize` (in-place split into `argv[16]`),
`dispatch_line` (walk a runtime builtin table — `echo`/`exit`/`pwd`/
`help`/`env`/`cd`), and `exec_child` (fork + execve `argv[0]`, wait).
It boots today, seeded at `/bin/sh`, driven by `init.pdx`'s live
fork/exec cycle.

That is the existence proof. The shape of ENH-002 through ENH-006 below
is deliberately the shape of `src/user/{shell,dispatch,builtins}.pdx`,
re-expressed against this repo's cap-narrowing and audit-first
invariants. This is a port with a security model bolted on, not a
research project.

---

## §4. The staged plan

Strict dependency order. Each stage is independently testable; nothing
later is startable without everything earlier.

### Stage 0 — the syscall floor (ENH-001)

The repo has zero syscall instructions. Every single deferred item in
`STATUS.md` — exec, wait, tty read, PdxFS write, audit send, broker send
— is blocked on this one absence. A `Syscall` module wrapping the SC+
IDs the shell needs (`read`=0, `write`=1, `open`=2, `close`=3,
`execve`, `wait4`, `chdir`=85, `getcwd`=86, `exit`=60) is the single
highest-leverage change in this plan, and nothing else in it can start
first.

Note the monorepo's one-file-one-ELF convention (`src/user/cat.pdx:127`):
tools there inline their syscalls rather than link a shim, specifically
to avoid object-set collisions. ENH-001 must decide, in-repo, whether
`shell` links a `Syscall` module or inlines — and record the decision.

**shell#44 addendum:** the ENH-001 enumeration lists nine sysnos and
deliberately omits `fork` (SC+ 56); the ENH-005 spawn path was a
degenerate "sys_execve replaces the shell" pattern that did not need
it. shell#44 adds `sys_fork` as the tenth wrapper and rewires
`exec_spawn_and_wait` to fork-before-exec, retiring the ENH-005
§FORK GAP. See `CHANGELOG.md` "Unreleased — shell#44" and
`design/architecture.md` §4.3.FORK GAP for the ground truth.

### Stage 1 — text becomes structure (ENH-002, ENH-003)

- **Lexer** (`src/lexer.pdx`): a byte buffer → token stream. Words,
  and the operators the existing encoders already presuppose: `|`
  (which `pipeline_plan` counts), `<`, `>`, `;`, `&`. Quote handling
  (`'`/`"`) and escape (`\`). Emits into a caller-owned token array;
  same `.bss`-singleton + fail-fast discipline as `Pds`.
- **Parser** (`src/parser.pdx`): token stream → a command list of
  pipelines of stages, each stage an `argv` slice. This is the missing
  producer of `pipeline_plan`'s `stages_count`. It should produce
  exactly the two things downstream consumers already want: the stage
  count (for `Pipeline`) and per-stage null-separated argv text (for
  `CommandRecord::command_record_begin`, which already takes
  `argv_ptr` + `argv_bytes`).

Designing the parser output *against the existing encoders' input
signatures* is the whole trick here. Both encoders were written to be
fed; nobody wrote the feeder.

### Stage 2 — in-process commands (ENH-004)

Builtin dispatch table: `cd`, `exit`, `export`, `pwd` at minimum.
`cd` calls the real `sys_chdir` (sysno 85, R86) and `pwd` the real
`sys_getcwd` (sysno 86) — not a stub, not a mirror. A `builtin`
concept does not exist anywhere in this repo today, including in
`design/architecture.md`; ENH-004 introduces it and amends that doc.

Note the design tension ENH-004 must resolve and record: the README
states shell "reads **no environment variables**" and treats env as an
ambient-authority channel the project avoids (plan.md D5). An `export`
builtin is in direct tension with that. ENH-004 either scopes `export`
to a shell-local variable table that is *not* inherited by children
(consistent with D5), or the D5 position is explicitly amended. It
must not silently do both.

### Stage 3 — out-of-process commands (ENH-005)

Replace the `EX_STUB` tail of `exec_spawn_and_wait` with the real
sequence the module's own §"M2 CALL GRAPH" already specifies: path
resolve → InitCap sidecar build → `cap_manifest_verify` →
`command_record_begin` (audit-first, **before** the child runs) →
`sys_execve` → `sys_wait4` → `command_record_close(exit)`. Honour
`design/user/execve-abi.md` exactly. The D3 audit-first invariant is
already tested (`taf_run_all`); ENH-005 is where it stops being a test
about an encoder and becomes a property of a running system.

### Stage 4 — the program (ENH-006)

Write `Shell::shell_main` — the symbol `manifest.pdxproj` has claimed
since M1 — and the REPL that ties the stages together: prompt → read →
lex → parse → dispatch (builtin) or exec (non-builtin) → history →
loop, exiting 0 on EOF. This is the first commit at which `shell` is a
shell.

### Stage 5 — de-stubbing the remainder (ENH-007, ENH-008, ENH-009)

- **ENH-007** `line_reader.pdx`: drop `LR_STUB`, read real bytes.
  Ships against the VFS `sys_read(0, …)` path; migrates to
  `KIND_TTY(read)` when the substrate lands (paideia-os#1986 gave us
  the op, but two further upstream landings — KIND_TTY loader-
  seedability + shell-time TTY row seed at boot — still gate the
  seam swap; see architecture.md §3.3, refreshed at #46).
  This is also the point at which the open R66 issues (#17–#21 —
  raw mode, backspace, history recall, cursor movement) become
  *startable*; they are line-editing polish on a read loop that does
  not exist yet.
- **ENH-008** `history.pdx`: persist the bytes `history_encode_record`
  already produces, via the now-real `KIND_PDXFS_FILE` write path.
- **ENH-009** `libpdx-elevate`: link it or drop it (§5).

### Stage 6 — tell the truth (ENH-010, ENH-011)

Documentation and issue-tracker correctness. §6 and §7.

---

## §5. The `libpdx-elevate` finding: mirrored, never linked

The README calls elevate integration "*reserved*, and honestly so."
That wording is accurate but understates how thin the connection is.
Precisely:

- **Declared as a build dependency:** `manifest.pdxproj:57` —
  `- libpdx-elevate @ ^0.2        # M5 reserved: .pds requires: elevate future`,
  with a five-line rationale at `manifest.pdxproj:47–51`.
- **One mirrored constant:** `src/shell.pdx:88` —
  `pub let SH_KIND_ELEVATE_CHANNEL : u64 = 0x191`. Grep for that
  symbol returns exactly two hits: its own definition and the comment
  citing its upstream at `src/shell.pdx:71`. **It is never read by any
  function in the repository.**
- **Zero call sites:** no `elevate_client_*` symbol is called anywhere.
  The nine other textual "elevate" hits in `src/` are all prose of the
  form "same shape as `elevate_client_lookup_broker`"
  (`src/line_reader.pdx:120`, `src/exec.pdx:84`, `src/shell.pdx:198`) —
  the library is cited as a *coding-style precedent for stub and
  counter idioms*, not invoked.
- **Not even requested at the cap layer:** `caps.decl`'s `requires:`
  block lists five KINDs and `KIND_ELEVATE_CHANNEL` is not among them.
  The shell does not hold the cap, so it could not call the broker even
  if it linked the client.

So "mirrors, doesn't link" means, exactly: *one unused ordinal constant
copied from the kernel, a manifest line reserving a version range, and
three comments admiring the library's stub idiom.* A `.pds` script
saying `requires: elevate` today would parse (`Pds` counts the pragma)
and then be silently ignored — there is no consumer of the parsed
capability list at all.

ENH-009 forces the choice: either genuinely link the client and request
`KIND_ELEVATE_CHANNEL` for privileged command paths, or drop the
manifest dependency and the dead constant. Carrying a declared
dependency that is never linked is a supply-chain claim the binary does
not honour — and it is worse than a no-op, because `pkg` and the
release manifest both surface `deps:` to users as a statement of what
the program actually uses.

---

## §6. The v1.0.0 verdict, and why the milestone is `v2.0` not `v0.2`

**Verdict: v1.0.0 misrepresents this repository and must be walked back
in documentation. `shell` is not, and has never been, an interactive
shell.** A program tagged 1.0.0 whose declared entry symbol does not
exist, which contains no syscall instruction, and whose only executed
call is a statistics counter, is a semver claim the artifact cannot
support. Anyone reading `pkg install shell` in the README's Examples
section is being told something untrue.

**But the tag itself stays.** Three reasons this is a documentation
demotion rather than a version reset:

1. `v1.0.0` is published and mirrored to
   `pkgs.paideia-os/main/shell/1.0.0/`. Deleting or moving a published
   tag breaks provenance for anything that already verified it.
2. The project's standing version discipline moves
   `workspace.version` + tag + `CHANGELOG` entry together, forward,
   at each phase close. A backward jump to `0.2.0` fights that rule
   and creates a second, contradictory ordering.
3. **The encoders genuinely are 1.0.** Twelve frozen wire formats with
   26 golden test cases is a defensible 1.0 *for a wire-format
   library*. The error was not the number; it was calling the artifact
   a shell.

Recommendation, therefore — **demote in prose, advance in numbering**:

- `STATUS.md` and `README.md` gain an unmissable banner: *v1.0.0 is a
  wire-format encoder suite. `shell` cannot execute a command.*
- The GitHub Release for `v1.0.0` is retitled to say the same.
- `manifest.pdxproj`'s `kind = tool` is reconsidered — an artifact with
  no entry point is not a tool.
- The first release in which `shell` executes a command is **`v2.0.0`**,
  which is why the milestone is named `v2.0 — real exec substrate`
  rather than `v0.2`. It is a genuine major change: the artifact's
  category changes from library to program.

This is ENH-010.

---

## §7. Issue-tracker correctness (ENH-011)

Eleven issues are open in this repo (#17–#27) across two milestones,
and both milestones are sequenced ahead of work that does not exist.

- **R66 (#17–#21)** — raw-mode input, backspace, history ring, cursor
  movement, design doc. Correctly scoped *as line-editing features*,
  but #17's body says "Extend `shell_read_line`" — a symbol that lives
  in the **monorepo's** `src/user/shell.pdx`, not here; this repo's
  function is `line_reader_read_line` and it returns a stub. These five
  are line-editing polish on a read loop that has not been written.
  They should be sequenced behind ENH-007, not blocked or refiled.
- **R73 (#22–#26)** — job control and tab completion. These bodies name
  `src/jobs.rs`, `src/builtins_bg_fg.rs`, `src/builtins_jobs.rs`,
  `src/completion.rs`, `src/fingerprint.rs`. **This repository contains
  zero `.rs` files and is written entirely in `.pdx` assembly.** The
  five bodies were filed from a Rust-shaped template and cannot be
  implemented as written. They also presuppose process groups, a
  builtin table, and a `PATH` walk, none of which exist. They need
  their file paths and idiom corrected, and sequencing behind ENH-004
  and ENH-006.

ENH-011 corrects these bodies and adds the dependency lines. It does
**not** refile their substance — the features are wanted, the
sequencing and the file paths are wrong.

---

## §8. Relationship to the `/bin/sh` cutover (do not re-decide)

`design/roadmap/rows-4-5-6-scoping.md` §4.2 in the monorepo already
settled this and this document defers to it entirely:

> **`paideia-os/shell` becomes the long-term source of truth.
> `src/user/shell.pdx` is retained, not retired, as the minimal
> early-boot shell until `paideia-os/shell`'s exec/session substrate is
> real enough to take over that role — then it is deprecated to a
> rescue-shell fallback, not deleted outright.**

The gate named there — "until `paideia-os/shell`'s exec path is proven
live under `init.pdx`'s actual fork/exec cycle" — **is exactly ENH-005
plus ENH-006 of this plan.** That is the whole significance of this
milestone: it is not incremental polish, it is the precondition the
monorepo's roadmap already wrote down for the `/bin/sh` handoff.

Monorepo-side companion work is consequently **flagged here and filed
elsewhere**, per the coordinating pass:

- `bin_seeds.pdx` seeding of a `shell`-produced ELF, and the smoke that
  proves it is a drop-in `/bin/sh` — monorepo-side, sequenced after
  ENH-006.
- `KIND_TTY` `TTY_OP_READ` + raw/cooked toggle — **paideia-os#1986,
  CLOSED 2026-08-31 (R66v2.POS-001, kernel commit 0e96c99).** ENH-007
  is deliberately designed not to block on it; shell-side migration of
  `lr_read_one_byte` to the cap-typed invoke is a further follow-up
  waiting on two additional paideia-os landings (KIND_TTY loader-
  seedability + shell-time TTY row seed at boot). See
  `design/architecture.md` §3.3 refresh at shell#46 for the ledger.

---

## §9. Issue index

Milestone: **`v2.0 — real exec substrate`** (milestone #8).

| ID | # | Title | Stage | Deps | Effort |
|---|---|---|---|---|---|
| ENH-001 | #28 | Syscall floor | 0 | none | M |
| ENH-002 | #29 | Lexer | 1 | none | M |
| ENH-003 | #30 | Parser | 1 | #29 | M |
| ENH-004 | #31 | Builtin dispatch table (`cd`/`exit`/`export`/`pwd`) | 2 | #28, #30 | M |
| ENH-005 | #32 | Real exec path (`sys_execve` + `sys_wait4`) | 3 | #28, #30 | L |
| ENH-006 | #33 | `Shell::shell_main` entry frame + REPL | 4 | #29, #30, #31, #32 | L |
| ENH-007 | #34 | `line_reader.pdx` de-stub | 5 | #28, #33 | M |
| ENH-008 | #35 | `history.pdx` de-stub (PdxFS write) | 5 | #28, #34 | M |
| ENH-009 | #36 | `libpdx-elevate`: link it or drop it | 5 | #28, #32 | M |
| ENH-010 | #37 | Walk back the v1.0.0 claim | 6 | none | S |
| ENH-011 | #38 | Correct + sequence the open R66/R73 issues | 6 | none | S |

The critical path to "`shell` is a shell" is
**#28 → #29 → #30 → #31/#32 → #33**. Everything else is either
de-stubbing behind that path or documentation. #37 and #38 carry no
dependencies and can land immediately.
