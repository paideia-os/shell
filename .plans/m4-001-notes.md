# shell.M4-001 — implementation notes

**Issue:** #12
**Title:** caps-narrowing violation matrix (child receives cap not in
its caps.decl → reject)
**Status:** LANDED
**Landed by:** Fix #12

## What landed

- `tests/test_caps_narrow.pdx` — `TestCapsNarrow` module: 8 test cases
  against `Exec.exec_narrow_child_caps` (M2-003), plus the umbrella
  `tcn_run_all` driver.

  Cases (all named `tcn_case_*`):

  | # | Name           | Fixture                                              | Expected              |
  |---|----------------|------------------------------------------------------|-----------------------|
  | 1 | happy          | parent=TTY(w) @slot=1 → 0x1000; child=TTY(w) @slot=1 | EX_OK                 |
  | 2 | narrowing      | parent=TTY(rw=0x3); child=TTY(r=0x1)                 | EX_OK, dst.rights=0x1 |
  | 3 | missing        | parent=TTY(w); child=PDXFS(w) — KIND not held        | EX_ERR_MISSING_CAP    |
  | 4 | widening       | parent=TTY(w=0x2); child=TTY(rw=0x3) — extra R bit   | EX_ERR_WIDENING       |
  | 5 | sidecar        | 3 caps, dst_max_entries=2                            | EX_ERR_SIDECAR_FULL   |
  | 6 | zero_decl      | child_decl_count=0                                   | EX_OK, dst untouched  |
  | 7 | bad_argv_parent| parent=0 (null)                                      | EX_ERR_BAD_ARGV       |
  | 8 | bad_argv_decl  | child_decl=0 (null)                                  | EX_ERR_BAD_ARGV       |

  Fixture buffers in .bss (`_tcn_parent`, `_tcn_child`, `_tcn_dst`,
  each 16 qwords = 128 bytes with 16-byte alignment). `tcn_reset`
  zeroes all three and paints the poison sentinel 0xDEADBEEF at
  `_tcn_dst[0]` so every reject case can verify "dst untouched" by a
  single-qword compare rather than a full-buffer memcmp.

  Fail codes in the 0xFFFFED0x band (disjoint from the shell's own
  0xFFFFECxx band so a caller distinguishes "test framework failed"
  from "SUT rejected input"):

  - `TCN_FAIL_HAPPY` (0xFFFFED01), `TCN_FAIL_NARROWING` (…02),
    `TCN_FAIL_MISSING` (…03), `TCN_FAIL_WIDENING` (…04),
    `TCN_FAIL_SIDECAR` (…05), `TCN_FAIL_ZERO_DECL` (…06),
    `TCN_FAIL_BAD_ARGV_P` (…07), `TCN_FAIL_BAD_ARGV_D` (…08),
    `TCN_FAIL_DST_MUTATED` (…09).

## Design decisions

### Wire-form fixtures via inline MOVs, not compile-time consts

The paideia-as syntax at this wave level exposes `uninit @align(N)`
for .bss + runtime MOV writes; there is no observed `const [u8;N] =
[...]` primitive in the shell repo. Each fixture setup builds its
wire records via 2-4 MOVs (one qword0 fused-slot|kind|rights + one
qword1 target_ptr per entry). This costs a handful of instructions
per test case but keeps the byte layout hand-verifiable at the test
site — a reader can compute the expected value from the wire-format
spec in `design/architecture.md` and match it against the MOV
constants directly.

### Poison sentinel 0xDEADBEEF at dst[0]

Every reject case (MISSING, WIDENING, SIDECAR_FULL, BAD_ARGV_*) must
prove the SUT respected the "reject leaves dst untouched" discipline.
Rather than checking every byte of a 128-byte buffer, `tcn_reset`
paints `_tcn_dst[0]` with 0xDEADBEEF; a subsequent reject that leaves
the sentinel intact is compact evidence the SUT never wrote to dst.
The value 0xDEADBEEF is a classic uninitialised-memory marker that
cannot be a legitimate wire record (kind lane would be 0xADBE, no
such KIND, and slot lane 0xBEEF is > SS_SLOT_MAX = 256 by wide
margin).

### Widening case rights choice

Parent has TTY(write = 0x2); child asks for TTY(read|write = 0x3).
The extra READ bit is the widen. This is the smallest possible
widen — 1 bit extra — which is the hardest case for the SUT to
detect because its widen check `(child & ~parent) == 0` must
correctly compute `(0x3 & ~0x2) = 0x1 != 0`. A wider widen (like
child asking for MINT+READ+WRITE when parent has only WRITE) would
still be detected by a broken check that only compared the WRITE
bit, which is why the fixture picks a minimal widen.

### Missing-cap case uses distinct KIND, not distinct rights

Parent has TTY(write); child asks for PDXFS_FILE(write). The KIND
differs (0x196 vs 0x195), so the inner-scan loop in the SUT walks
through all parent entries without finding a match. If the fixture
had used same-KIND with different rights, the widen check would be
the discriminator and this case would collapse into `tcn_case_
widening` — the MISSING path would go untested.

### Sidecar overflow uses a 3-entry decl with dst_max=2

The gate in the SUT is `cmp r9, r15; jb en_nc_sidecar_full` where
r9=dst_max_entries and r15=child_decl_count. Fixture picks 3 vs 2 so
the gate fires clearly; the parent set has 3 matching caps so if the
gate were absent the SUT would proceed to write 3 entries into a
2-entry buffer (overwriting whatever sits at dst+32). The 128-byte
dst buffer is wide enough that this bug wouldn't crash the test, but
`_tcn_dst[0]`'s poison sentinel would be overwritten — the
DST_MUTATED path catches that.

### Fail codes in a separate band (0xFFFFED0x)

The shell owns 0xFFFFECxx; the test module owns 0xFFFFED0x.
Distinguishing them lets an operator reading a test-run log tell
"the SUT refused the input" (0xFFFFECxx) from "the test framework
detected the SUT did the wrong thing" (0xFFFFED0x). If both bands
lived in 0xFFFFECxx, a fail code 0xFFFFEC01 might be mistaken for a
real shell error at a diagnostic call site.

## paideia-as conformance checklist

- Module name PascalCase basename (`TestCapsNarrow`): yes.
- No `test` mnemonic: yes — every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses imm <= 0x7FFFFFFF: yes (largest is
  256 = 0x100 in tcn_reset's loop bound; the loop bound 16 in the
  larger reset is well under).
- Large immediates (wire-form fused qword0 values 0x00000002_01960001
  etc., 0xDEADBEEF sentinel, error codes 0xFFFFEC2x, fail codes
  0xFFFFED0x) via `mov r10, imm64` / `mov r11, imm64`.
- `r11` scratch (paideia-as reserved) used for `lea r11, [rip + sym]`
  reads of expected-value large-imm compares in verifier tail code.
- Byte reads: no byte reads at the fixture-setup layer — every
  fixture write is a qword store. The SUT's byte reads are its own
  concern.
- Every non-leaf test entry: 6 pushes (rbx, rbp, r12, r13, r14, r15)
  + `sub rsp, 8` = 56 bytes prologue; rsp % 16 == 0 for the
  exec_narrow_child_caps call.
- Matched epilogue at every return: yes; the four exit tails per
  case (OK + up to 2 distinct fail codes) each pop in reverse order
  before `ret`.

## What later milestones build on top

- **M4-003 QEMU smoke** — the `tcn_run_all` return is one of the
  pre-QEMU gates the paideia-os smoke harness checks; a non-zero
  return means the caps-narrowing invariant fails and the smoke run
  is not attempted.
- **M5-001 dual-signed release** — the paideia-as build lint at
  release time re-runs `tcn_run_all` to confirm the invariant still
  holds against the final release binary; a change to
  `exec_narrow_child_caps` that regresses the narrower would be
  caught before signature.
- **doc.M1 (cross-repo cycle break)** — per §5.2, "doc in turn
  depends on shell.M4 for its runtime — this is the one direct cycle
  in the R49 DAG, broken by shell.M4 (test-complete but pre-release)
  unblocking doc.M1". Test-complete means M4-001..003 land; this
  test's compilable-and-passing status is one of the three signals.
- **Cross-repo (libpdx-cap M4)** — libpdx-cap's own
  `cap_manifest_verify` fuzzer will re-use the same wire-form
  fixtures once libpdx-cap M4 lands, so the golden bytes here become
  the canonical smallest-fixture bank for both sides.
