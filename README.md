# shell

Interactive shell for PaideiaOS — tokenizer + dispatcher + builtins.

## Status

R106 wave scaffold. `src/` and `tests/` continue to carry the R49
v1.0.0 encoder-half body (session mint, pipeline plan, semantic-pipe
passthrough, audit-first command records, release-manifest encoder);
the R106 wave lands a real tokenizer + dispatcher + builtin table on
top of that substrate. This repo's R106.SHELL-001 issue closes out the
scaffold so R106.SHELL-002 (tokenizer) and R106.SHELL-003 (test
infra) can move code in without setup friction.

## Dependency chain

- **paideia-as** — the assembler. Resolved via the standard
  `find-paideia-as.sh` chain (`tools/build.sh`). Version floor is
  paideia-as v0.29.2 at time of R106 scaffold; substrate-half work
  will re-pin to whatever floor the tokenizer needs.
- **libpdx-argv** — typed argv parsing for `.pds` shebangs and shell
  flags. Consumed by `src/pds.pdx`; the R106 tokenizer/dispatcher
  reuses the same parser for `-c` and script-arg extraction.

Additional dependencies (libpdx-cap, libpdx-audit,
libpdx-semantic-pipe, libpdx-elevate) are declared in
`manifest.pdxproj` for the R49 encoder body and remain load-bearing
under R106.

## Cross-references

- **Wave plan (R106+):** paideia-os
  [`design/roadmap/persistent-home-wave.md`](https://github.com/paideia-os/paideia-os/blob/main/design/roadmap/persistent-home-wave.md)
  — the round-by-round schedule this repo's R106 milestone tracks.
  §"Cross-repo scaffolding" names R106.SHELL-001 (this issue) and
  paideia-os's paired R106.M4-KERNEL kernel-side integration surface.
- **Identity model:** paideia-os
  [`design/user/content-addressed-identity.md`](https://github.com/paideia-os/paideia-os/blob/main/design/user/content-addressed-identity.md)
  — the content-addressed identity substrate this shell dispatches
  against. Novel departure from POSIX $USER / uid ambient authority;
  every prompt, history record, and command frame carries a
  content-address rather than a name.
- **Tokenizer landing:** [R106.SHELL-002 (#41)](https://github.com/paideia-os/shell/issues/41)
  — the actual tokenizer move (novel-tilde, bare-cd errors, dispatch
  entrypoint).
- **Test infrastructure:** [R106.SHELL-003 (#42)](https://github.com/paideia-os/shell/issues/42)
  — tokenizer + dispatcher test infrastructure.

## Layout

```
caps.decl              capability requests + declared output schemas
manifest.pdxproj       paideia-as build manifest
src/                   R49 encoder body; R106 tokenizer/dispatcher land here
tests/                 R49 golden-fingerprint tests; R106 adds tokenizer suites
tools/build.sh         paideia-as build gate (find-paideia-as.sh resolver)
design/                architectural specs (architecture.md, enhancement-plan.md)
doc/shell.pdxdoc       `doc shell` source
.plans/                per-milestone implementation notes
```

## Building

```
bash tools/build.sh
```

The build gate resolves paideia-as via `find-paideia-as.sh`,
enumerates every `.pdx` file under `src/`, and reports source/failure
counts. Zero failures means the encoder body still assembles under
the current paideia-as floor.

## Historical note (R49 v1.0.0)

The R49 wave shipped the encoder half of a full shell (session
mint, pipeline plan, cap narrowing, `.pds` header parser, history
persistence encoder, semantic-pipe passthrough, tab-completion
encoder, ShellCommandRecord audit encoder, ReleaseManifest encoder,
`svc.login-shell` broker-bind encoder). See
[`design/architecture.md`](design/architecture.md),
[`doc/shell.pdxdoc`](doc/shell.pdxdoc), and the pre-R106 CHANGELOG
entries for the full v1.0.0 surface. Substrate wiring (KIND_TTY,
`sys_execve`, `sys_ipc_send` to `svc.audit-journal`, PdxFS write)
stayed deferred to a paideia-os round adjacent to R49 and is being
picked up as part of the R106+ persistent-home wave.

## License

MIT — see LICENSE.
