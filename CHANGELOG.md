# shell — CHANGELOG

All notable changes to this project. The format follows Keep a
Changelog conventions; the project follows Semantic Versioning per
`design/tooling/plan.md` §6.

## 1.0.0 — 2026-08-22

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
