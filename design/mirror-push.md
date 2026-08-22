# shell — mirror-push protocol

**Wave:** R49 (Wave 1)  **Milestone:** M5-002  **Issue:** #16
**Upstream design:** [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6.3 (repository model);
[`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.2 M5-002 line.

## 0. What this document pins

The bytes and paths that reach `pkgs.paideia-os` when the shell
v1.0 release lint completes. The mirror does not exist at HEAD
(2026-08-22) — this document is the input contract the mirror is
built against, so the first shell release does not need a schema
negotiation with a moving-target mirror.

## 1. Mirror file tree

Per [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6.3, the mirror is a static HTTP(S)-served tree. After a
successful shell v1.0 push, the tree contains:

```
pkgs.paideia-os/
  index.pdxsig                              ← updated: adds one row for shell/1.0.0
  shell/
    1.0.0/
      pkg.tar                               ← the shell package archive
      manifest.pdxsig                       ← dual-signed manifest (byte-identical to the copy inside pkg.tar)
```

`pkg.tar` is a POSIX tar of the contents of
`/pkgs/shell-1.0.0/`:

```
pkg.tar contents:
  bin/shell
  caps.decl
  deps.list
  doc/shell.pdxdoc
  manifest.pdxsig    ← same bytes as ../manifest.pdxsig above
```

The duplicated `manifest.pdxsig` (inside the tar AND alongside it)
lets a local `pkg verify /pkgs/shell-1.0.0/` re-check the
signatures without a network round trip.

## 2. `index.pdxsig` update

`index.pdxsig` is a signed manifest of `{name, version, hash}`
tuples (`design/tooling/plan.md` §6.3). The shell v1.0 push adds
one row:

```
name       = shell
version    = 1.0.0
sha3_256   = <sha3-256 of the shell pkg.tar>
signer     = paideia_root_pk
signed_at  = <unix seconds>
```

`pkg` clients query `index.pdxsig` for the `{name, version}` they
want, download the referenced `manifest.pdxsig`, verify its two
signatures against the ML-DSA-65 pubkeys in the manifest body
(cross-check the fingerprints against the operator's local key
store), then download the `pkg.tar` and unpack under
`KIND_PDXFS_TXN` scope.

Adding a row to `index.pdxsig` re-signs the whole index — no
partial-update path. This is intentional: the whole index is one
signature, so a mirror operator that adds a package without the
`paideia_root_pk` cannot silently inject a package the index does
not attest to.

## 3. Push discipline

The `paideia-as release --push` step (last of the five release-lint
gates in [`release-manifest.md`](release-manifest.md) §4) proceeds
in this order:

1. **Assemble the tar.** Package the tree from §1 into
   `build-out/shell-1.0.0.tar`. Deterministic ordering: files
   sorted lexicographically inside the tar so the sha3-256 is
   reproducible across build hosts.
2. **Compute pkg.tar hash.** sha3-256 of the tar bytes. Record
   into the row that will be added to `index.pdxsig`.
3. **Fetch current index.** `GET pkgs.paideia-os/index.pdxsig` and
   verify its `paideia_root_pk` signature. Refuse to proceed if
   verification fails — the operator's local key store might be
   out of date, and the whole point of the sig check is to catch
   this before adding a row that would inherit the mismatch.
4. **Append shell/1.0.0 row + re-sign.** Adds the row from §2 and
   re-signs the whole index with `paideia_root_pk`. Existing rows
   are byte-preserved; the sha3 of a row that was already there
   does not change.
5. **Push atomic.** Upload `pkg.tar`, `manifest.pdxsig`, and the
   updated `index.pdxsig` in this order. `index.pdxsig` is
   overwritten LAST because a client that fetches the new index
   between the first two uploads and the third would find rows
   pointing at bytes that don't yet exist. The overwrite is
   atomic at the mirror side (rename over the old file); a client
   that reads mid-rename gets one or the other, never a partial.

If any step fails after step 5 starts (mirror rejects the upload,
network drops mid-push), the release lint refuses to mark the tag
`v1.0.0` as pushed and the operator retries after diagnosing.
Half-pushed state is detectable via `pkg update` from any client:
the tar hash in `index.pdxsig` will not match the tar bytes on the
mirror, and `pkg install shell` refuses the install with a
verification error.

## 4. Rollback

Shell rollback follows the general pkg rollback flow
(`design/tooling/plan.md` I5 — every install writes an undo record
to `/journal/pkg/`). A `pkg undo install shell` restores the
pre-shell-1.0.0 state locally; the mirror-side row for
`shell/1.0.0` is NOT retracted (the mirror is append-only for
signed releases). A superseding shell/1.0.1 release publishes a
new row that clients update to via `pkg update`.

## 5. Deferred substrate

- The `pkgs.paideia-os` mirror itself is scaffolded in a follow-up
  paideia-os round; this document is the input contract.
- `paideia-as release --push` reaches its final shape once
  paideia-as v0.33-crypto-kdf lands the ML-DSA-65 sign path (see
  [`release-manifest.md`](release-manifest.md) §5).
- `pkg update` polling frequency and the mirror-side rate limiter
  are pkg.M2+ concerns; shell's release does not observe them.
