# shell.M4-003 — implementation notes

**Issue:** #14
**Title:** QEMU smoke: login → prompt → ls | cat → history persists
across reboot
**Status:** LANDED (encoder-half; substrate-wired smoke gated on
paideia-os side)
**Landed by:** Fix #14

## What landed

- `tests/test_smoke_matrix.pdx` — `TestSmokeMatrix` module: 4
  fixture+verifier cases that produce and validate the exact wire
  bytes the paideia-os side's post-boot smoke checker will look for
  in an actual `ls | cat` run.

  Cases (all named `tsm_case_*`):

  | # | Name       | Encoder(s) driven                                      | Golden output                  |
  |---|------------|--------------------------------------------------------|--------------------------------|
  | 1 | pipeline   | `pipeline_plan(stages=2, dst_max=4)`                   | 2×16-byte pipe caps            |
  | 2 | ls_cmdrec  | `command_record_begin`+`_close` for argv="ls\0"        | 56-byte CLOSED record          |
  | 3 | cat_cmdrec | `command_record_begin`+`_close` for argv="cat\0"       | 56-byte CLOSED record          |
  | 4 | hist       | `history_encode_record("ls | cat", 8 bytes)`           | 32-byte HistoryEntry           |

  Fixture buffers in .bss:
  - `_tsm_pipe` — 64 bytes (8 qwords) for pipeline plan output.
  - `_tsm_ls_rec` — 128 bytes for the ls CommandRecord.
  - `_tsm_cat_rec` — 128 bytes for the cat CommandRecord.
  - `_tsm_hist` — 64 bytes for the HistoryEntry.
  - `_tsm_ls_argv` — 8 bytes for "ls\0" (3 bytes + zeros).
  - `_tsm_cat_argv` — 8 bytes for "cat\0" (4 bytes + zeros).
  - `_tsm_hist_cmd` — 16 bytes for "ls | cat" (8 bytes + zeros).

  `tsm_reset` zero-fills every buffer and re-populates the three
  byte-fixtures deterministically.

  Fail codes in the 0xFFFFED2x band:
  - `TSM_FAIL_PIPELINE` (0xFFFFED21), `TSM_FAIL_LS_BEGIN` (…22),
    `TSM_FAIL_CAT_BEGIN` (…23), `TSM_FAIL_HIST` (…24),
    `TSM_FAIL_PIPELINE_GLD` (…25), `TSM_FAIL_LS_GOLDEN` (…26),
    `TSM_FAIL_CAT_GOLDEN` (…27), `TSM_FAIL_HIST_GOLDEN` (…28).

## What DID NOT land (substrate-blocked)

The QEMU smoke itself — the interactive `login → prompt → run ls | cat
→ observe records in audit journal → reboot → observe history file
carries the entry` — lives on the paideia-os side, in
`tools/verify-user-shell.sh` (or a companion script). It requires:

- **Userspace `sys_execve` / `sys_wait4` wrappers.** The shell repo
  ships `exec_spawn_and_wait` at its EX_STUB skeleton (M1-003); the
  actual sys_execve dispatch is a substrate deferral. Paideia-os
  R17 lands the kernel side; a shell-repo wrapper needs to link
  against it.
- **Userspace `sys_ipc_recv` / endpoint-mint.** `pipeline_plan`
  writes wire records that carry placeholder pipe ids; the M4+
  substrate replaces them with real endpoint ids returned by
  `sys_ipc_recv`. Without this, the two children exec against unpaired
  placeholder endpoints and the smoke silently hangs on the reader.
- **Userspace PdxFS-write path.** History persistence requires
  `sys_ipc_send(svc.pdxfs-journal, encoded_bytes)`. `KIND_PDXFS_FILE`
  landed at R42 scaffold (commits 411ad0e, 2ff76d4) but the userspace
  write wrapper is not linked in the shell repo at HEAD.
- **Userspace `sys_ipc_send` to `svc.audit-journal`.** The audit
  journal broker's userspace send path pairs with libpdx-audit M2.
  Cross-repo linkage lands at M4+ when all sides pull into one build.
- **QEMU + serial-console-scripted interactive run.** paideia-os
  `tools/run-qemu.sh` + `tools/_shell_test_driver.py` already exist
  as the framework; a shell.M4-003 smoke script wires them to the
  scenario.

The four encoder-half fixtures in this module are the PRE-BOOT gate
for the paideia-os smoke harness: if the encoders' golden bytes have
drifted from what the post-boot checker looks for, there is no point
booting the guest. `tsm_run_all` returns 0 on all-pass and a
distinct fail code otherwise; the paideia-os harness reads the
return value and either proceeds to boot or fails with a diagnostic.

## Design decisions

### Split by "encoder half" (this repo) + "substrate half" (paideia-os)

The QEMU smoke is inherently cross-repo — it needs a booting kernel
that hosts the shell process. The shell repo cannot boot itself. The
encoder half (producing correct wire bytes) is what the shell repo
CAN test locally; the substrate half (running under a booted kernel)
is a paideia-os concern. Splitting the responsibility this way keeps
each repo's tests self-contained: shell repo tests never require a
QEMU harness; paideia-os tests never require re-deriving the wire
format.

### Golden byte values derived by hand from the wire spec

Every expected value in this module is computed at authoring time
from the wire-format spec in `src/pipeline.pdx`,
`src/command_record.pdx`, and `src/history.pdx` — the same specs the
SUT encoders read from. The derivations are in the case
justifications:

- Pipeline entry qword0 = slot | (kind << 16) | (rights << 32);
  slot=1, kind=5, rights=0x2 → 0x00000002_00050001.
- CommandRecord qword0 = magic | (record_len << 32); magic =
  0x52444d43, record_len = (48+argv+7)&~7 → 0x00000038_52444d43
  for both ls (argv=3) and cat (argv=4).
- HistoryEntry qword0 = magic | (record_len << 32); magic =
  0x54534948 (LE "HIST"), record_len = (24+8+7)&~7 = 32 →
  0x00000020_54534948.

If a future encoder change breaks the wire format silently, the
golden compares fire immediately.

### Two CommandRecords with different audit_ids

The `ls | cat` scenario produces TWO ShellCommandRecords, one per
child. audit_id 0x1001 for ls, 0x1002 for cat — arbitrary but
non-zero and distinct so the paideia-os smoke checker can pair
records with children by ID rather than by argv text matching.
libpdx-audit's `audit_begin` issues monotonic IDs starting from
some base; the smoke checker knows to expect (base+0) and (base+1),
not the specific 0x1001/0x1002 values used here. This test's role
is proving the encoder honours whatever ID it's passed.

### History-cmd bytes match "ls | cat" exactly

The shell reads "ls | cat" from KIND_TTY (8 characters); the
history record's cmd_bytes field is that same 8-byte string. This
means the persistence half of the smoke (`history` after reboot
should display "ls | cat" verbatim) reduces to a byte-exact match
between what the encoder writes and what the post-boot `history`
tool reads back. The 8-byte value at offset 24..31 of `_tsm_hist`
is checked byte-by-byte in `tsm_case_hist` to nail this contract.

### No fixture for the actual sys_execve / wait pair

By design. The syscall side is what the paideia-os smoke tests;
this repo's role is proving the encoders produce what the syscalls
would carry. Adding a fake execve fixture here would be misleading
— it would suggest the shell repo can test the child-unblock
timing, which it cannot.

## paideia-as conformance checklist

- Module name PascalCase basename (`TestSmokeMatrix`): yes.
- No `test` mnemonic: yes.
- Every `cmp reg, imm` uses imm <= 0x7FFFFFFF: yes (largest is 32
  in the history verifier, well under).
- Large immediates via `mov r10, imm64` / `mov r11, imm64`.
- `r11` scratch.
- Byte writes in `tsm_reset` use `mov_b [ptr], rax` after loading
  rax with the byte constant.
- Byte reads in `tsm_case_hist`'s verifier use
  `xor rax, rax; mov_b rax, [ptr]` (#1248 pattern).
- Every non-leaf test entry: 6 pushes + `sub rsp, 8` = 56 bytes
  prologue; rsp % 16 == 0 for the SysV encoder calls.

## What later milestones build on top

- **M5-001 dual-signed release** — release-time lint runs
  `tsm_run_all` to confirm the encoders still produce the golden
  bytes. Any drift here is a release-blocking regression.
- **paideia-os side smoke wiring** — the paideia-os smoke harness
  script (to land at paideia-os R49 close as `tools/verify-user-
  shell.sh` or similar) calls this module's `tsm_run_all` as a
  pre-boot gate before invoking `tools/run-qemu.sh` with the
  scripted interactive session.
- **doc.M1** — same cross-repo cycle break as M4-001/002; a passing
  M4-003 encoder-half is one of the three signals doc.M1 needs to
  unblock its own scaffolding.

## Cross-repo dependency notes

- The paideia-os smoke harness (currently non-existent for the R49
  wave; softarch should file a paideia-os issue to bring it under
  `tools/verify-user-shell.sh`) is the canonical driver for the
  substrate half. This test's golden fingerprints are the input
  contract that harness will consume.
- libpdx-audit's own M4 will independently verify the send-with-
  durable-ack path against a spun-up broker; the encoder half
  tested here is the "record shape" input that path assumes.
- libpdx-semantic-pipe's M4 will verify the passthrough discipline
  end-to-end on a real endpoint pair; this test's pipeline_plan
  fixture is what a real pipe endpoint should look like at the
  wire layer.
