# shell.M5-002 — .pdxdoc for doc shell + mirror push

**Issue:** paideia-os/shell#16
**Design:** `design/tooling/r49-r50-plan.md` §5.2 M5-002 line;
`design/tooling/plan.md` I7 (help + tutorial + example-gallery
required per tool); `design/pdxdoc-source.md` (this repo);
`design/mirror-push.md` (this repo).

## What landed

- `doc/shell.pdxdoc` — the doc-source for `doc shell`. Front-
  matter block declares name / version / kind / authors /
  license; body sections in the order specified by
  `design/pdxdoc-source.md` §3: SYNOPSIS, DESCRIPTION, OPTIONS,
  EXAMPLES, FILES, ENVIRONMENT (declared empty, per the
  section's own convention to omit-when-empty; kept in for
  the "why empty" explanation), EXIT_STATUS, DIFFERENCES_FROM_
  POSIX (five bullets covering env-var absence, audit-first,
  visible cap handoff, cap-declared IPC endpoints, schema-typed
  pipes), SEE_ALSO (twelve cross-references), CAPABILITIES_
  REQUESTED (mirrors caps.decl), SIGNING (both fingerprints
  with the release-signer-populated placeholder).
- `design/pdxdoc-source.md` — the source-form conventions the
  `.pdxdoc` file follows. Section marker discipline, cross-
  reference syntax (`<tool>(1)`, `<library>(3)`, `<file>(5)`,
  `design://<path>`), POSIX-difference annotation shape, and
  UTF-8 encoding notes. Sits alongside doc.M1-002's eventual
  parser as the authoring-surface spec.
- `design/mirror-push.md` — the `pkgs.paideia-os` mirror-push
  protocol: file-tree layout under `<name>/<version>/`,
  `index.pdxsig` row shape, atomic-push discipline (upload
  pkg.tar + manifest.pdxsig first; index.pdxsig LAST via
  rename-over so a client reading mid-push gets one consistent
  state or the other, never a half-picture), rollback via
  append-only index + superseding release.

## What the module boundaries witness

- **I7 help + tutorial + example-gallery required.** The
  `.pdxdoc` covers the `doc <tool>` half of I7. The `--help`
  emitter and `--tutorial` / `--examples` gallery paths land
  when the shared library `pdx-help` reaches R51 (per
  `design/tooling/plan.md` §7); at M5-002 shell is the FIRST
  tool with a shipping `.pdxdoc`, so it serves as the
  reference source for doc.M1's parser test corpus.
- **§6.3 mirror model.** The push discipline documents the
  mirror as append-only for signed releases (a v1.0.0 row is
  never retracted; a v1.0.1 supersedes it). This mirrors how
  `pkg keys` treats key fingerprints: additive, never
  overwriting.
- **Cross-repo coupling recap.** doc.M1 has doc.M1-002
  (`.pdxdoc` file-format parser); shell.M5-002 ships a source
  file exercising every section the parser will need to
  handle. The two land in the same wave; the shell docs are
  the parser's first authoritative input corpus.

## Cross-repo dependency notes

- **doc.M1** — is the direct downstream consumer of the
  `.pdxdoc` produced here. Cross-repo cycle: shell.M5-002
  reads `design/tooling/r49-r50-plan.md` §5.3 for the
  parser's expected shape; doc.M1 reads
  `design/pdxdoc-source.md` in this repo for the authoring
  surface. Both sides are pinned in text spec before either
  code lands.
- **pkgs.paideia-os mirror** — does not exist at HEAD. This
  document is the input contract the first mirror
  implementation reads.
- **pkg.M5** — pkg's own M5 lands at the same time as
  shell.M5 (per `design/tooling/r49-r50-plan.md` §5.1 M5
  line). Both repos push to the same mirror on the same
  discipline; if pkg's M5 wave introduces further mirror-
  side requirements, `design/mirror-push.md` is amended
  during the pkg wave, not this one.

## What later milestones build on top

- **doc.M1-002 parser corpus.** The doc parser's first test
  input is this repo's `doc/shell.pdxdoc`. A well-formed round-
  trip is one of the M1 acceptance gates.
- **doc.M4 rendering test suite.** The `.pdxdoc` here supplies
  one of the shipped tools' docs; the rendering suite pipes
  it through the M2 pagination + cross-reference navigation
  code.
- **R56+ multi-session mux.** When shell learns multi-session,
  the `doc/shell.pdxdoc` gains a section on the mux mode; the
  update rides the R56 shell wave's own M5.
