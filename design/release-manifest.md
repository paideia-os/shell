# shell — release manifest

**Wave:** R49 (Wave 1)  **Milestone:** M5-001  **Issue:** #15
**Upstream design:** [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
D4 (dual-signed install model) + §6.3 (repository model);
[`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.2 M5 line (shell release scope).
**Authoritative wire spec:** [`pkg/design/manifest-format.md`](https://github.com/paideia-os/pkg/blob/main/design/manifest-format.md)
§4 (pkg.M1-003) — the format is shared across every tool in the
tooling wave; this document is the shell-specific instance.

## 0. Reading order

- §1 — what a shell v1.0 `manifest.pdxsig` says.
- §2 — the eleven KV records shell emits and the value of each.
- §3 — sigblock policy: the two ML-DSA-65 signers, key rotation,
  and the M5-001 zero-fill placeholder.
- §4 — the release lint sequence (`trm_run_all` → sign → mirror
  push) and the fail-fast contract.
- §5 — deferred substrate + the paideia-as toolchain floor.

## 1. What the manifest says

A `manifest.pdxsig` accompanies `bin/shell`, `caps.decl`,
`deps.list`, and `doc/shell.pdxdoc` inside the shell v1.0 package
tarball. `pkg install shell` reads the manifest first, verifies
the two ML-DSA-65 signatures, cross-checks the hashes for
`caps.decl` and `deps.list`, and only then extracts the binary
into `/pkgs/shell-1.0.0/`.

The manifest is a codec, not a schema — its byte layout is fixed
by [`pkg/design/manifest-format.md`](https://github.com/paideia-os/pkg/blob/main/design/manifest-format.md)
§4, and this repo's `src/release_manifest.pdx` module is the
encoder half. The pkg-side decoder
(`pkg/src/manifest_codec.pdx`) parses exactly the bytes this
repo's encoder produces; a drift here is a drift there and the
M5-001 test matrix (`tests/test_release_manifest.pdx`) is the
first line of defence against it.

## 2. Shell v1.0 KV inventory

Eleven KV records ship in the body section, in this order:

| # | Tag                    | Value for shell v1.0                          |
|---|------------------------|-----------------------------------------------|
| 1 | `PKG_NAME`         (0x0001) | `"shell"` (5 bytes)                         |
| 2 | `PKG_VERSION`      (0x0002) | `"1.0.0"` (5 bytes; semver per §6 of plan)  |
| 3 | `PKG_REPO_URL`     (0x0003) | `"github.com/paideia-os/shell"` (28 bytes)  |
| 4 | `PAIDEIA_AS_VER`   (0x0004) | `"0.33-crypto-kdf"` (15 bytes; toolchain floor) |
| 5 | `AUTHOR_PUBKEY`    (0x0010) | 1952-byte ML-DSA-65 pubkey of `paideia-os-team` |
| 6 | `AUTHOR_FPR`       (0x0011) | 32-byte sha3-256 fingerprint of AUTHOR_PUBKEY |
| 7 | `AUTHOR_EXPIRY`    (0x0012) | `0` (u64; 0 = never)                          |
| 8 | `ROOT_PUBKEY`      (0x0020) | 1952-byte ML-DSA-65 pubkey of `paideia_root_pk` (R32) |
| 9 | `ROOT_FPR`         (0x0021) | 32-byte sha3-256 fingerprint of ROOT_PUBKEY   |
|10 | `ROOT_EXPIRY`      (0x0022) | `0` (u64; 0 = never)                          |
|11 | `CAPS_DECL_HASH`   (0x0030) | 32-byte sha3-256 of packaged `caps.decl`     |
|12 | `DEPS_LIST_HASH`   (0x0031) | 32-byte sha3-256 of packaged `deps.list`     |
|13 | `FILE_INVENTORY`   (0x0040) | one per file — see below                     |
|14 | `BUILD_REPRODUCER` (0x00F0) | UTF-8 attribution string                     |

The `FILE_INVENTORY` records (repeated tag 0x0040) enumerate every
file under the packaged tree:

- `bin/shell` (mode 0o755, sha3-256 of the elaborated binary)
- `caps.decl` (mode 0o644, sha3-256 of the on-disk file)
- `deps.list` (mode 0o644, sha3-256 of the on-disk file)
- `doc/shell.pdxdoc` (mode 0o644, sha3-256 of the doc source)

The `caps.decl` and `deps.list` FILE_INVENTORY records duplicate
the hash already recorded in the standalone CAPS_DECL_HASH /
DEPS_LIST_HASH tags — this duplication is documented in
[`pkg/design/manifest-format.md`](https://github.com/paideia-os/pkg/blob/main/design/manifest-format.md)
§4.3 last paragraph and is intentional (fast-lookup optimisation
that saves a second inventory walk at install time).

## 3. Sigblock

Two ML-DSA-65 signatures cover the concatenation `header || body`.
Both signers use identical parameters:

- Algorithm: ML-DSA-65 at NIST security level 2 (3293-byte
  signatures; `RM_SIG_LEN_MLDSA65_L2` in
  [`src/release_manifest.pdx`](../src/release_manifest.pdx)).
- Signing key: private-key file held out-of-tree; the public key
  ships in the body as `AUTHOR_PUBKEY` / `ROOT_PUBKEY`.
- Signature envelope: pkg §4.4 layout (u32 length prefix + bytes).

### 3.1 The two signers

- `author_pk` — the paideia-os-team key. Signs the manifest first;
  proves the package came from the tool's maintainers.
- `paideia_root_pk` — the R32 root key. Re-signs the manifest
  after the author signature is present; proves the package
  reached the mainline paideia-os distribution channel.

`pkg install shell` verifies BOTH signatures. Either failing
refuses the install. `pkg install --from-source shell` skips the
author signature (the user is building their own binary from
verified source) but still verifies the source-tree root against
the author key per `design/tooling/plan.md` D4 last paragraph.

### 3.2 M5-001 placeholder

The paideia-as toolchain at HEAD (2026-08-22) has not yet reached
the v0.33-crypto-kdf tag that lands ML-DSA-65 sign
(`src/kernel/core/crypto/mldsa/mldsa65_sign.pdx` per
`design/security/pe-secure-boot-signing.md` §PBS-D1).
`release_manifest_encode_sigblock_slot(dst, dst_len, offset,
sig_len=3293, sig_ptr=0)` therefore ships as a zero-fill call — the
length prefix is set to 3293 so envelope offsets stay measurable at
release lint time; the zero-filled bytes are replaced in place by
the real signer bolt-on once the toolchain reaches the floor.

The `test_release_manifest.pdx` `trm_case_broker_bind` fixture (and
the header + KV goldens) do NOT depend on the sigblock at all — the
sigblock byte range is orthogonal to the header + body layout, so
the M5 encoder-half goldens land ahead of the signer.

## 4. Release lint sequence

The `paideia-as release --sign` invocation runs these five gates
in order, and refuses to sign on any non-zero return:

1. **Repo status clean.** `git status --porcelain` must be empty
   and `git rev-parse HEAD` must match a tag matching `v1.0.0`.
2. **All tests pass.** `paideia-as build --tests` builds and runs
   the four tests targets from `manifest.pdxproj`:
   `tcn_run_all`, `taf_run_all`, `tsm_run_all`, `trm_run_all`.
   Every return must be zero. The M5 addition here is `trm_run_all`
   — the release lint is the second entry point besides the QEMU
   smoke that consumes the M5 goldens.
3. **Manifest encoding.** The release tool walks the packaged
   tree, sha3-hashes every file, and calls the encoders in
   `src/release_manifest.pdx` to assemble the header + body per
   §2. The body sha3-256 is then computed and stamped into the
   header (offsets +24 and +32 via `release_manifest_encode_
   header_prefix` — the first 16 bytes of the digest ride in the
   header per pkg §4.1 for fast-fail; the full 32-byte compare
   happens at install time from the body payload).
4. **Sigblock.** The signer receives `header || body` and emits
   two ML-DSA-65 signatures. `release_manifest_encode_sigblock_
   slot` writes each into the sigblock section with its length
   prefix. At M5-001 the encoder receives `sig_ptr = 0` (zero-fill
   placeholder); the signer bolt-on replaces the zeros in place.
5. **Mirror push.** See [`mirror-push.md`](mirror-push.md).

## 5. Deferred substrate

The M5 encoder half is complete; the substrate half stays deferred
to the following paideia-os rounds:

- **ML-DSA-65 sign path.** Blocked on paideia-as v0.33-crypto-kdf
  reaching the toolchain (see `design/security/pe-secure-boot-
  signing.md` §PBS-D1). Until then the sigblock is zero-filled
  behind correct length prefixes.
- **sha3-256 in-line hashing.** The release tool calls the R32
  sha3 code (`src/kernel/core/crypto/sha3/`) out-of-band; the
  encoder receives already-computed hash halves.
- **Broker registration substrate.** `sys_ipc_send` to the
  R20b.M1-003 broker (`src/kernel/core/ipc/svc_broker.pdx`) is
  wrapped in userspace as part of a paideia-os round adjacent to
  R49; `broker_bind_login_shell` returns `BB_STUB` in the interim.
  See [`../src/broker_bind.pdx`](../src/broker_bind.pdx) module
  header for the substrate-half hand-off.
- **`pkgs.paideia-os` mirror.** The mirror itself does not exist
  at HEAD; [`mirror-push.md`](mirror-push.md) documents the
  protocol so the mirror can accept the first shell release
  without a schema negotiation.
