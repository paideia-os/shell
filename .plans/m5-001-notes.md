# shell.M5-001 — dual-signed release + svc.login-shell broker registration

**Issue:** paideia-os/shell#15
**Design:** `design/tooling/r49-r50-plan.md` §5.2 M5 line;
`design/release-manifest.md` (this repo); `design/mirror-push.md`
(this repo); `pkg/design/manifest-format.md` §4 (authoritative
wire spec, mirrored on the encoder side by
`src/release_manifest.pdx`).

## What landed

- `src/release_manifest.pdx` (369 lines) — `ReleaseManifest`
  module. Four entry points that together assemble a
  byte-conformant `manifest.pdxsig`:
    * `release_manifest_encode_header_prefix` — offsets 0..48
      (magic / format_version / header_flags / body_len /
      body_sha3_256_lo / body_sha3_256_hi / sigblock_len).
    * `release_manifest_encode_header_suffix` — offsets 48..64
      (pubkey_len_author packed with pubkey_len_root as u32
      halves of a single u64, plus created_unix_secs).
    * `release_manifest_encode_kv` — one KV record per pkg §4.2
      (u16 tag + u16 len + value bytes; supports RM_TAG_PKG_NAME,
      RM_TAG_PKG_VERSION, RM_TAG_PAIDEIA_AS_VER, RM_TAG_AUTHOR_
      PUBKEY, RM_TAG_AUTHOR_FPR, RM_TAG_AUTHOR_EXPIRY, RM_TAG_
      ROOT_PUBKEY, RM_TAG_ROOT_FPR, RM_TAG_ROOT_EXPIRY, RM_TAG_
      CAPS_DECL_HASH, RM_TAG_DEPS_LIST_HASH, RM_TAG_FILE_
      INVENTORY, RM_TAG_BUILD_REPRODUCER via the RM_TAG_* mirror
      of the pkg-side registry).
    * `release_manifest_encode_sigblock_slot` — one sigblock
      slot per pkg §4.4 (u32 length prefix + sig bytes). The
      `sig_ptr == 0` branch is the M5 placeholder: zero-fills the
      sig payload behind the correct length prefix so envelope
      offsets stay measurable at release lint time.
- `src/broker_bind.pdx` (287 lines) — `BrokerBind` module.
  `broker_bind_login_shell(dst, dst_len, endpoint_cap, name_ptr,
  name_len, rights_mask) -> u64` writes the three-qword
  BrokerBindRequest header (BB_MAGIC | rec_len fused,
  endpoint_cap, rights_mask | name_len fused) + UTF-8 name bytes
  + 0..7 zero-padding, then returns `BB_STUB` (0xFFFFECB0) --
  the encoder-half sentinel while `sys_ipc_send` to
  `svc.audit-journal` broker's wrapper substrate is deferred.
- `manifest.pdxproj` — bumped version 0.4.0-m4 → 1.0.0, added
  the two new sources + the M5 test module to sources: /tests:
  lists, added `docs:` list pointing at `doc/shell.pdxdoc`, added
  a `release:` block naming the two signers, the ML-DSA-65
  security level, the broker name, and the mirror target.
- `CHANGELOG.md` — new file, v1.0.0 entry landed with the M5
  additions + a summary of the four pre-release milestones.
- `tests/test_release_manifest.pdx` (~540 lines) — 4-case
  encoder-golden matrix (`trm_case_hdr_prefix`,
  `trm_case_hdr_suffix`, `trm_case_kv`, `trm_case_broker_bind`)
  driven by `trm_run_all`. Fail-code band 0xFFFFED3x.
- `design/release-manifest.md` — the shell-specific view of the
  pkg-wide manifest format: which of the pkg §4.2 tags shell
  emits, in what order, with what values; the sigblock
  placeholder scheme; the release-lint sequence.

## What the module boundaries witness

- **D4 dual-signed install model.** Every KV tag needed to
  express `author_pk`, `paideia_root_pk`, their fingerprints and
  expiries is in the RM_TAG_* registry. The sigblock encoder
  reserves the two ML-DSA-65 signature slots at the exact
  offsets a signed release ships.
- **§6.3 repository model.** The manifest.pdxproj `release:`
  block names `mirror_target = pkgs.paideia-os/main/shell/1.0.0/`;
  the mirror-push.md protocol pins the file-tree layout under
  that path.
- **R49-PREP-005/006 broker naming.** The svc.login-shell name
  follows the `svc.<caller-class>-<provider-class>` pattern
  R48-PREP-005 (svc.elevate-broker) and R49-PREP-006
  (svc.audit-journal) established.

## paideia-as conformance (per file)

Both new source modules observe the shell repo's ambient
discipline exactly as history.pdx / command_record.pdx do:

- Module basename PascalCase (`ReleaseManifest`, `BrokerBind`).
- No `test` mnemonic; every zero-check via `cmp reg, 0`.
- Every `cmp reg, imm` uses imm <= 0x7FFFFFFF (KV_LEN_MAX 65535,
  SIG_LEN_MAX 8192, NAME_MAX 256 all fit trivially).
- Large immediates (RM_MAGIC_QWORD, BB_MAGIC, error codes) via
  `mov r10, imm64`.
- `r11` unused in every entry body (no .bss reach).
- Byte loads through the #1248 pattern
  (`xor rax, rax; mov_b rax, [ptr]`) and byte stores through
  `mov_b [ptr], rax`.
- Prologue sized so `rsp % 16 == 0` for every nested call.

## What later milestones build on top

There are no shell milestones after M5 in the R49 wave — the
next work on this repo is R56+ (multi-session mux + remote
shell). What follows here is what M5-001 unblocks for OTHER
repos + rounds:

- **paideia-as v0.33-crypto-kdf** — the ML-DSA-65 sign path
  bolts onto `release_manifest_encode_sigblock_slot` by
  replacing the zero-fill payload with a real signature at the
  same offset. No layout change.
- **paideia-os R20b broker-registration schema** — completes
  `sys_ipc_send` wrappers; the shell's `_start` frame calls
  `broker_bind_login_shell` once at boot, expects `BB_STUB` to
  become `BB_OK` (a new positive success sentinel added at that
  substrate PR), then hands the returned endpoint cap to the
  broker.
- **doc.M1** — reads `doc/shell.pdxdoc` (M5-002 delivery) using
  the source-form spec in `design/pdxdoc-source.md`.
- **pkg.M2 install path** — reads shell's `manifest.pdxsig` at
  install time via `pkg/src/manifest_codec.pdx`; the pkg-side
  decoder consumes exactly the bytes this repo's encoder
  produces.
