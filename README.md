# shell

paideia-os Paideia shell (semantic-pipes aware, elevate-integrated)

## Status

M1 complete. See `design/tooling/r49-r50-plan.md` §5.2 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo for the
milestone breakdown, KIND allocations, cross-repo dependencies, and
per-milestone issue set. See `STATUS.md` in this repo for the M1
rollup and the 0xFFFFECxx return-code band.

## Local layout

- `design/architecture.md` — internal spec (module boundary, return-
  code band, paideia-as conformance, M4 test matrix).
- `src/shell.pdx` — `Shell` module (KIND ordinal mirrors, error
  band, `_shell_stats` singleton, `shell_reset` / `shell_note` /
  `shell_stat`).
- `src/line_reader.pdx` — `LineReader` module
  (`line_reader_read_line` skeleton returning `LR_STUB`).
- `src/exec.pdx` — `Exec` module (`exec_spawn_and_wait` skeleton
  returning `EX_STUB`).
- `caps.decl` — shell caps declaration (KIND_USER + KIND_TTY +
  KIND_IPC_ENDPOINT + KIND_SHELL_SESSION; ShellPromptRecord +
  CommandCompletion + ShellCommandRecord).
- `tests/` — empty until `shell.M4-001` lands the pipeline
  correctness matrix and the QEMU interactive smoke.
- `.plans/` — per-milestone implementation notes.

## License

MIT — see LICENSE.
