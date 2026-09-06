# shell — CHANGELOG

All notable changes to this project. The format follows Keep a
Changelog conventions; the project follows Semantic Versioning per
`design/tooling/plan.md` §6.

## Unreleased — ENH-003: parser (#30)

The v1.0.0 audit found that `Pipeline::pipeline_plan` took a
pre-counted `stages_count` and `CommandRecord::command_record_begin`
took per-stage null-separated argv text — both were written to be
FED but nobody wrote the feeder. ENH-002 closed the byte-level split
(Lexer); ENH-003 closes the pipeline-level split. Consumes the Lexer
token stream in `_lx_tokens` / `_lx_token_count` and produces a
command list of pipelines-of-stages in fresh `.bss` singletons.
Pure-function; no substrate touch.

### Added

- `src/parser.pdx` — `Parser` module. `parser_parse(input_ptr,
  input_len) → u64` reads the Lexer singletons and populates
  `_pr_stages` (8 stages × 3 qwords: argv_offset, argv_bytes, argc),
  `_pr_stage_count`, and `_pr_argv_pool` (4096-byte contiguous byte
  pool). Words are copied byte-for-byte from the source buffer,
  NUL-separated with a trailing NUL after each word. `PR_MAX_STAGES
  = PL_MAX_STAGES = 8` — a valid parser output is always handable to
  `pipeline_plan` without a second gate. Fresh return-code sub-band
  `0xFFFFECDx`: `PR_ERR_TOO_MANY_STAGES`, `PR_ERR_LEADING_PIPE`,
  `PR_ERR_TRAILING_PIPE`, `PR_ERR_EMPTY_STAGE`,
  `PR_ERR_ARGV_POOL_OVERFLOW`. Non-WORD, non-PIPE tokens (REDIR_*,
  SEMI, AMP) silently skipped at ENH-003; semantics land in
  ENH-004/ENH-005/ENH-006.
- `tests/test_parser.pdx` — `TestParser` module. Eight cases in the
  `0xFFFFED6x` band: `bare_ls`, `pipe`, `pipe_flags`,
  `leading_pipe`, `trailing_pipe`, `empty_stage`, `too_many` (9
  stages), and the LOAD-BEARING `golden_feed` case that wires
  parser output into `pipeline_plan` for `ls | cat` and asserts the
  4 qwords byte-match the existing `tsm_case_pipeline` golden.
  Umbrella `tpr_run_all` matches the family shape.
- `design/architecture.md` §2c — Parser module documentation
  (contract, output shape, downstream contract, error codes,
  fingerprint) matching the §2b Lexer shape.
- `design/architecture.md` §5 and §7.4 — return-code table extended
  with the `0xFFFFECDx` Parser rows and the `0xFFFFED6x` TestParser
  row.

### Changed

- `src/shell.pdx` — mirrored `SH_PR_*` constants in the
  `0xFFFFECDx` band alongside the existing `SH_LX_*` mirrors, so a
  Shell-level caller can spell every parser sentinel without an
  explicit Parser import.
- `manifest.pdxproj` — `src/parser.pdx` registered after
  `src/lexer.pdx` and before `src/line_reader.pdx` (parser consumes
  lexer output, feeds line_reader-driven exec at ENH-006);
  `tests/test_parser.pdx` appended to the test list.
- `STATUS.md` — return-code table extended with the five
  `0xFFFFECDx` Parser rows.

### Unblocks

`#31` builtin dispatch (consumes `_pr_stages[0]`'s first argv word to
choose between builtin and exec paths), `#32` real exec (needs the
per-stage argv slices this parser produces), `#33` `shell_main` REPL
(assembles read → lex → parse → exec). The critical path from
ENH-002 through ENH-006 is now open at the parser boundary.

## Unreleased — ENH-002: lexer (#29)

The v1.0.0 audit found no lexer in the tree; ENH-002 lands one. `Lexer`
turns a caller-owned byte buffer into a token stream in a `.bss`
singleton table. Recognises words, five single-byte operators
(`|<>;&`), single- and double-quoted strings, and backslash escape.
Pure-function; no substrate touch.

### Added

- `src/lexer.pdx` — `Lexer` module. `lexer_tokenize(input_ptr,
  input_len) → u64` populates the `.bss` singletons `_lx_tokens` (128
  × 24-byte records) and `_lx_token_count`. Token vocabulary:
  `TOK_WORD`, `TOK_PIPE`, `TOK_REDIR_IN`, `TOK_REDIR_OUT`, `TOK_SEMI`,
  `TOK_AMP`, `TOK_EOF` (reserved). Fresh return-code sub-band
  `0xFFFFECCx` (LX_ERR_OVERFLOW, LX_ERR_UNTERMINATED_QUOTE,
  LX_ERR_INVALID_ESCAPE, LX_ERR_BAD_ARGS) — the issue's suggested
  `0xFFFFEC5x` collides with the existing Pds allocation.
- `tests/test_lexer.pdx` — `TestLexer` module. Seven golden-fingerprint
  cases (bare `ls`, `ls -l`, `ls | cat`, `ls | cat > /tmp/f`,
  `echo 'a b'`, empty line, whitespace-only line) + umbrella
  `tlx_run_all`, in the `0xFFFFED5x` fail-code band. Matches the
  `tsf_run_all` driver family shape.
- `design/architecture.md` §2b — Lexer module documentation
  (contract, token vocabulary, grouping rules, error codes,
  fingerprint) matching the §2a shape ENH-001 established.
- `design/architecture.md` §5 and §7.4 — return-code table extended
  with the `0xFFFFECCx` Lexer row and the `0xFFFFED5x` TestLexer row.

### Changed

- `src/shell.pdx` — mirrored `SH_LX_*` constants in the
  `0xFFFFECCx` band alongside the existing `LR_*` / `EX_*` mirrors,
  so a Shell-level caller can spell every lexer sentinel without an
  explicit Lexer import.
- `manifest.pdxproj` — `src/lexer.pdx` registered after
  `src/shell.pdx` and before `src/line_reader.pdx` (logical order:
  lexer is a lower-level primitive the line reader will feed at
  ENH-006); `tests/test_lexer.pdx` appended to the test list.

### Unblocks

`#30` parser (consumes the token stream), `#31` builtin dispatch
(dispatches on `TOK_WORD[0]`), `#32` real exec (needs the argv
token stream), `#33` `shell_main` REPL (assembles the read → lex →
parse → exec pipeline). The critical path from ENH-002 through
ENH-006 is now open at the tokenizer boundary.

## Unreleased — ENH-001: syscall floor (#28)

First `syscall` instructions land in the tree. The v1.0.0 audit
(`design/enhancement-plan.md` §1) verified zero `syscall` occurrences
in `src/`; this change lands nine, one per SC+ wrapper the shell v2.0
plan enumerates (Stage 0 in the enhancement plan).

### Added

- `src/syscall.pdx` — `Syscall` module. Nine sysno constants
  (`SYS_READ=0`, `SYS_WRITE=1`, `SYS_OPEN=2`, `SYS_CLOSE=3`,
  `SYS_EXECVE=59`, `SYS_EXIT=60`, `SYS_WAIT4=61`, `SYS_CHDIR=85`,
  `SYS_GETCWD=86`) plus a thin callable wrapper per constant. Each
  wrapper is a leaf function: `mov rax, N; [mov r10, rcx for arity=4];
  syscall; ret`. Effect and capability annotations mirror the
  monorepo's canonical `src/user/syscall_shim.pdx` for each SC+ ID.
- `tests/test_syscall_floor.pdx` — `TestSyscallFloor` module. Runtime
  fingerprint with two cases (`tsf_case_getcwd`, `tsf_case_write`) +
  umbrella `tsf_run_all`, in the `0xFFFFED4x` fail-code band. Same
  driver shape as the four existing test modules; a boot-time smoke
  harness can invoke all five umbrellas in one loop.
- `design/architecture.md` §2a — records the design decision (shared
  module, not per-callsite inline) with the syscall_shim.pdx precedent,
  documents the wrapper surface + calling convention + fingerprint.
- `design/architecture.md` §7.4 — extends the fail-code-band table with
  `0xFFFFED3x` (TestReleaseManifest, prior omission) and `0xFFFFED4x`
  (TestSyscallFloor).

### Changed

- `manifest.pdxproj` — `src/syscall.pdx` registered ahead of
  `src/shell.pdx` in the source list (the shell v2.0 wire will call
  Syscall from Shell::shell_main; source order is documented as
  order-insensitive per the paideia-as module resolver, but the
  logical dependency reads better this way);
  `tests/test_syscall_floor.pdx` appended to the test list.

### Unblocks

Every v2.0 downstream (`#29` lexer, `#30` parser, `#31` builtin
dispatch, `#32` real exec, `#33` shell_main REPL, `#34` line_reader
de-stub, `#35` history de-stub) that had "no syscall substrate" as
its blocker. The critical path from ENH-001 through ENH-006 is now
open at the substrate boundary.

## 0.1.0 — 2026-09-03 — R106.SHELL-001 scaffold consolidation

R106 wave opens. Repo version resets to the R106 wave's 0.1.0 baseline;
R49's v1.0.0 encoder body remains in `src/` and continues to build
under paideia-as v0.29.2. Scaffold consolidation lands the last
pre-landing chores so R106.SHELL-002 (tokenizer) and R106.SHELL-003
(test infra) can move code in without setup friction.

### Added

- `.gitignore` — build-out/, target/, *.o, *.elf, .DS_Store, and
  common editor scratch.
- README.md — R106 mission line, dependency chain (paideia-as +
  libpdx-argv), cross-refs to paideia-os
  `design/roadmap/persistent-home-wave.md` (wave plan) and
  `design/user/content-addressed-identity.md` (novel identity model),
  and cross-refs to R106.SHELL-002 (#41) and R106.SHELL-003 (#42).
- STATUS.md — R106 milestone header + placeholder progress table;
  R49 v1.0.0 material demoted to a historical section.

### Changed

- `manifest.pdxproj` version 1.0.0 → 0.1.0 (R106 wave baseline).

### Cross-refs

- Wave plan: paideia-os `design/roadmap/persistent-home-wave.md` §R106
  + §"Cross-repo scaffolding".
- Paired paideia-os issue: R106.M4-KERNEL.

## 1.0.0 — 2026-08-22

> **Retroactive correction (2026-09-05, shell#37 / ENH-010):** "First
> stable release" below overclaims. `v1.0.0` is a wire-format encoder
> suite — twelve wire encoders and pure bitmask narrowers — not an
> executable shell: zero syscall instructions in `src/`, and its
> declared entry symbol (`Shell::shell_main`) was never written. See
> `design/enhancement-plan.md` §1 for the grep-verified audit and §6
> for why the release that first executes a command is `v2.0`, not
> `v0.2`. The tag and signed release stand as published; only the
> "stable release" / "full shell" characterization below is withdrawn.

**First stable release.** Shell binds itself to the `svc.login-shell`
broker name at session start (M5-001); the login supervisor's path
now has a discoverable endpoint. Dual-signed `manifest.pdxsig` per
`design/manifest-format.md` (pkg §4) is emitted by the release-time
signer via the `ReleaseManifest` encoder introduced this release;
sigblock payloads land once paideia-as reaches the v0.33-crypto-kdf
floor. `.pdxdoc` for `doc shell` ships at `doc/shell.pdxdoc` (M5-002)
and mirrors to `pkgs.paideia-os/main/shell/1.0.0/` per
`design/mirror-push.md`.

### Added (M5)

- `src/release_manifest.pdx` — `ReleaseManifest` module. Wire
  encoder for `manifest.pdxsig` per pkg §4 (header prefix + suffix +
  KV records + sigblock slots). Emits the eleven-tag body layout
  shell v1.0's manifest ships. Sigblock placeholder path zero-fills
  the two ML-DSA-65 signature payloads while pinning the length
  prefixes to 3293 bytes (NIST security level 2) so envelope offsets
  measured by the release lint match the signed release.
- `src/broker_bind.pdx` — `BrokerBind` module. Encoder for the
  `svc.login-shell` broker-bind request the shell sends to the
  paideia-os service broker (R20b.M1-003 at
  `src/kernel/core/ipc/svc_broker.pdx`) at session start.
  `broker_bind_login_shell(dst, dst_len, endpoint_cap, name_ptr,
  name_len, rights_mask)` writes the three-qword header +
  UTF-8 name + zero-padding and returns `BB_STUB` (encoder
  validated; `sys_ipc_send` deferred to M4+ substrate).
- `doc/shell.pdxdoc` — the doc source for `doc shell`, following
  the section conventions in `design/pdxdoc-source.md`. Covers
  synopsis, pipeline model, capability handoff, `.pds` scripts,
  history, differences from POSIX bash/zsh, and the see-also graph.
- `manifest.pdxproj` — paideia-as build manifest bumped to v1.0.0;
  adds `release_manifest.pdx` and `broker_bind.pdx` to the source
  list, `test_release_manifest.pdx` to the test list, and
  `doc/shell.pdxdoc` to the docs list. New `release:` section names
  the signer keys, the ML-DSA security level, the broker name, and
  the mirror target.
- `tests/test_release_manifest.pdx` — 6-case encoder-golden test
  matrix for `ReleaseManifest`: header prefix, header suffix, a
  KV record, a sigblock slot in zero-fill mode, and two hard-reject
  cases (name too long, truncated dst). Golden bytes derived from
  the wire specs and checked in-source via `mov r11, imm64; cmp rax,
  r11`. Umbrella driver `trm_run_all` returns 0 or 0xFFFFED3x.
- `design/release-manifest.md` — shell-specific tag inventory and
  the sigblock placeholder scheme. Sits alongside pkg's
  authoritative wire spec (`design/manifest-format.md`).
- `design/pdxdoc-source.md` — the `.pdxdoc` source-file conventions
  shell adopted for `doc/shell.pdxdoc`; the doc.M1-002 parser is
  the eventual reader.
- `design/mirror-push.md` — the `pkgs.paideia-os` mirror-push
  protocol (file-tree layout, `index.pdxsig` contribution shape,
  hand-off discipline).
- Fail-code bands `0xFFFFECAx` (ReleaseManifest) and `0xFFFFECBx`
  (BrokerBind) added to the 0xFFFFECxx shell error table; test-code
  band `0xFFFFED3x` added for `TestReleaseManifest`.

### Changed

- `manifest.pdxproj` version 0.4.0-m4 → 1.0.0 (see above).

### Deferred to substrate

The release-time ML-DSA-65 sign path and the `sys_ipc_send` wrapper
for the broker-bind wire message stay deferred to a paideia-os round
adjacent to R49 that lands (a) v0.33-crypto-kdf and (b) the broker-
registration IPC schema. Encoder-half testing is in place; the
substrate half slots in without a schema re-negotiation because the
encoder pinned the bytes at M5.

## 0.4.0-m4 — 2026-08-22 (pre-release)

M4 close: tests + smoke matrix (encoder half). See `STATUS.md`.

## 0.3.0-m3 — 2026-08-22 (pre-release)

M3 close: semantic-pipe passthrough + tab-completion + audit
integration.

## 0.2.0-m2 — 2026-08-21 (pre-release)

M2 close: core implementation (session mint, pipeline plan, cap
narrowing at exec, `.pds` executor, history persistence encoder).

## 0.1.0-m1 — 2026-08-21 (pre-release)

M1 close: design + skeleton (Shell / LineReader / Exec modules;
`caps.decl`; return-code band).
