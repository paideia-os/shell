# shell

paideia-os Paideia shell (semantic-pipes aware, elevate-integrated).

## Status

**v1.0.0** — first stable release. M1..M5 landed under
[`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.2. See `STATUS.md` for the milestone rollup, the 0xFFFFECxx
return-code band, and the substrate deferrals; see `CHANGELOG.md`
for the release-by-release view.

## Local layout

- `manifest.pdxproj` — paideia-as build manifest at v1.0.0.
  Lists sources, tests, docs, deps, compliance flags, and the
  release-policy block (signers + broker name + mirror target).
- `caps.decl` — shell caps declaration (KIND_USER + KIND_TTY +
  KIND_IPC_ENDPOINT + KIND_SHELL_SESSION + KIND_PDXFS_FILE;
  emits ShellPromptRecord + CommandCompletion +
  ShellCommandRecord schemas).
- `CHANGELOG.md` — release-by-release changes.
- `src/` — one module per `.pdx` file. `Shell` /
  `LineReader` / `Exec` / `Session` / `Pipeline` / `Pds` /
  `History` / `PipePassthrough` / `Completion` / `CommandRecord`
  / `ReleaseManifest` / `BrokerBind`.
- `tests/` — the encoder-half `TestCapsNarrow` /
  `TestAuditFirst` / `TestSmokeMatrix` / `TestReleaseManifest`
  modules; the release-time lint (`design/release-manifest.md`
  §4) invokes each `t*_run_all` driver as a pre-sign gate.
- `doc/shell.pdxdoc` — the doc source for `doc shell`
  (M5-002; renders via `doc` at doc.M2+).
- `design/architecture.md` — internal spec (module boundary,
  return-code band, paideia-as conformance).
- `design/release-manifest.md` — shell-specific view of the pkg
  §4 manifest.pdxsig format (M5-001).
- `design/pdxdoc-source.md` — the `.pdxdoc` source-file
  conventions this repo's `doc/shell.pdxdoc` follows (M5-002).
- `design/mirror-push.md` — the `pkgs.paideia-os` mirror-push
  protocol (M5-002).
- `.plans/` — per-milestone implementation notes.

## License

MIT — see LICENSE.
