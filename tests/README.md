# tests/

Empty at M1 by design. The correctness matrix — pipeline
correctness (2-stage, 3-stage, cross-schema, schema-mismatch),
caps-narrowing violation (child receives cap not in its caps.decl →
reject), audit-first invariant (child cannot emit before audit
record is durable), `.pds` script test suite, and the QEMU
interactive smoke (login → prompt → `ls | cat` → history persists
across reboot) — lands with `shell.M4-001` through `shell.M4-003`
per `design/tooling/r49-r50-plan.md` §5.2 in paideia-os.

The M1 skeleton wired here (Shell / LineReader / Exec) is validated
against its own return-code contract at M2, when the pipeline
substrate lands and the `_start` frame binds the run loop. Every M1
entry point already returns its documented `LR_STUB` / `EX_STUB` /
`LR_ERR_BAD_BUF` / `EX_ERR_BAD_ARGV` sentinels so the M2 tests can
diff a live run against the M1 skeleton with a mechanical rule
(`if rc == LR_STUB: still on M1; if rc == LR_OK: M2 live`).
