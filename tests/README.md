# tests/

M4 landed here (issues #12, #13, #14 per
`design/tooling/r49-r50-plan.md` §5.2 in paideia-os). Every fixture
is a pure-function driver against a shell-repo encoder / narrower;
no substrate calls, no QEMU, no live filesystem. The three modules
compile against paideia-as and expose a `*_run_all` entry each that
returns 0 on all-pass or a distinct `0xFFFFED*x` fail code otherwise.

## Files

- `test_caps_narrow.pdx` (shell.M4-001, issue #12) — `TestCapsNarrow`
  module: 8 test cases against `Exec.exec_narrow_child_caps` (M2-003).
  Covers HAPPY, NARROWING, MISSING, WIDENING, SIDECAR_FULL, ZERO_DECL,
  and two BAD_ARGV null-pointer cases. Fail code band 0xFFFFED0x.
  Driver: `tcn_run_all()`.

- `test_audit_first.pdx` (shell.M4-002, issue #13) — `TestAuditFirst`
  module: 8 test cases against `CommandRecord.command_record_begin`
  and `command_record_close` (M3-003). Covers BEGIN_OK, CLOSE_EXIT0,
  CLOSE_EXIT1, CLOSE_NO_BEGIN, CLOSE_EXIT_OOR, BEGIN_ID_ZERO,
  CLOSE_PENDING, and a load-bearing ORDERING round-trip. Fail code
  band 0xFFFFED1x. Driver: `taf_run_all()`.

- `test_smoke_matrix.pdx` (shell.M4-003, issue #14) — `TestSmokeMatrix`
  module: 4 encoder-half fixtures for the `ls | cat` QEMU smoke.
  Produces + validates the golden wire bytes for a 2-stage pipeline,
  two ShellCommandRecords, and one HistoryEntry. The substrate half
  (booted QEMU + serial-console-scripted interactive `login → prompt
  → ls | cat → reboot → history`) is a paideia-os-side script gated
  on this module's `tsm_run_all()` returning 0. Fail code band
  0xFFFFED2x.

- `test_exec_alignment.pdx` (shell#44 retroactive) —
  `TestExecAlignment` module: 3 test cases witnessing the
  `rsp % 16 == 0` invariant that shell#19 commit 88580b5 restored
  on `Exec::exec_spawn_and_wait`. Case 1 replicates the POST-fix
  prologue (5 callee-save pushes, no `sub rsp, 8`) and asserts
  post-prologue rsp%16==0; case 2 replicates the PRE-fix (buggy)
  prologue and asserts the counter-example (rsp%16==8 post-stray-
  sub); case 3 round-trips the real SUT via its BAD_ARGV gate
  (argc=0). Fail code band 0xFFFFEDFx. Driver: `teal_run_all()` --
  emits `EXEC ALIGN OK\n` via sys_write(1, ...) on all-pass so the
  paideia-os QEMU boot smoke can grep-assert it. Future enhancement
  note: replace the arithmetic `and rax, 15` witness with a
  `movaps [rsp], xmm0` hard-fault probe once paideia-as gains
  packed-SSE emission (#1333 deferred; only scalar-float lands
  today).

- `test_tokenizer.pdx` (R106.SHELL-003, issue #42) —
  `TestTokenizer` module: 14 test cases against R106.M1
  `Tokenizer.tokenize` (src/tokenizer.pdx). Covers empty, ws-only,
  bare, two-words, single-quote, double-quote, double-quote-escape,
  bare-escape, adjacent-fragment glue, unterminated single,
  unterminated double, invalid escape, overflow, and bad-args. Fail
  code band 0xFFFFEDBx. Driver: `ttk_run_all()`. The three
  #41-dependent test files (`tokenizer_tilde.pdx`,
  `tokenizer_bare_cd.pdx`, `dispatch_argv_construction.pdx`) the
  issue body names land alongside R106.SHELL-002 (#41) where the
  novel-tilde / bare-cd-error / dispatch-argv-plumbing SUT symbols
  first exist -- band 0xFFFFEDCx reserved.

## Driver entry points

Each `*_run_all` returns:

- `0` — all cases in that module passed.
- `0xFFFFED0x` — first failing case in test_caps_narrow.
- `0xFFFFED1x` — first failing case in test_audit_first.
- `0xFFFFED2x` — first failing case in test_smoke_matrix.
- `0xFFFFEDBx` — first failing case in test_tokenizer.
- `0xFFFFEDFx` — first failing case in test_exec_alignment.

The bands are disjoint from the shell's own 0xFFFFECxx band
so an operator reading a test-run log can distinguish "SUT rejected
input" from "test framework detected the SUT did the wrong thing"
by the high two bytes of the return alone.

## What is NOT here

- **Live QEMU smoke.** The `login → prompt → ls | cat → history
  persists across reboot` interactive run lives on the paideia-os
  side, gated by `tsm_run_all()` as its pre-QEMU checker. See
  `.plans/m4-003-notes.md` for the substrate gaps.
- **Fuzzers.** M4 rubric names "pre-release fuzzers"; the encoder-
  half here is deterministic-fixture-driven, sufficient for the
  8-case matrix + 8-case matrix + 4-case matrix that M4-001/002/003
  spec. Fuzz-corpus generation lands at M5 (release-prep) when
  libpdx-cap's caps.decl fuzzer generates cross-tool cap manifests
  for the caps_narrow SUT.
- **libpdx-* cross-repo integration.** The shell tests use the
  shell's own encoders only. libpdx-audit / libpdx-cap / libpdx-
  semantic-pipe / libpdx-argv have their own test modules; the
  cross-repo linkage lands with paideia-os smoke harness pulling
  all sides into one build.
