# shell

Interactive shell for PaideiaOS — tokenizer + dispatcher + builtins +
REPL.

> **ENH-006 (#33) lands `Shell::shell_main` and the REPL.** The commit
> that lands #33 is the first at which `shell` is a shell:
> `src/shell.pdx` now defines the ELF entry (`shell_main`), the CLI
> flag walker (`shell_argv_dispatch`) that recognises `-c` /
> `--no-history` / `--no-cap:<KIND>` / positional `<script.pds>`, and
> the one-line REPL (`shell_repl_step`) that runs lex -> parse ->
> dispatch -> exec. `manifest.pdxproj` `kind` flips back to `tool`.
> ENH-007 (#34) lands the real bytes into `line_reader_read_line`
> (byte-at-a-time `sys_read` from fd 0 behind a single seam
> `lr_read_one_byte`; the cap-typed `KIND_TTY(read)` invoke is
> deferred behind that same seam until paideia-os#1986 lands
> `KIND_TTY_OP_READ`). One runtime gap remains as a documented
> deferral: ENH-008 (#35) persists the in-memory history ring to
> `~/.history/`. See
> [`design/enhancement-plan.md`](design/enhancement-plan.md) §1 for
> the grep-verified audit and §6 for why the release that first
> executes a command is `v2.0`, not `v0.2` (shell#37 / ENH-010).

## Synopsis

```
shell [-c <command>] [--no-history] [--no-cap:<KIND>] [<script.pds>]
```

## Options

| Flag                 | Behaviour                                                                          |
|----------------------|------------------------------------------------------------------------------------|
| `-c <command>`       | Run `<command>` once through the REPL step then `sys_exit(0)`. Non-interactive.   |
| `--no-history`       | Skip the `history_encode_record` append after each line (ring stays empty).       |
| `--no-cap:<KIND>`    | Refuse to hand children the named `KIND` cap. Flag is remembered; the KIND parse + cap-narrowing hook lands with ENH-005+ wiring. |
| `<script.pds>`       | Positional. Recorded in `_sm_opt_script_ptr`; `.pds` script execution lands with the `Pds` runtime wiring (M2-004 encoder is done, dispatcher hookup is future work). |

Any other flag returns `SM_ERR_ARG_FLAG_UNKNOWN` (0xFFFFECF0), which
`shell_main` maps to `shell: unknown flag\n` on stderr + `sys_exit(1)`.

## Maturity

The exec substrate is live (ENH-001 syscall floor, ENH-002 lexer,
ENH-003 parser, ENH-004 builtins + dispatcher, ENH-005 real
sys_execve + audit-first ShellCommandRecord, ENH-006 shell_main +
REPL, ENH-007 real line-reader bytes). `line_reader_read_line` now
issues real `sys_read(0, ptr, 1)` byte-at-a-time reads behind a
single seam (`lr_read_one_byte`); the cap-typed `KIND_TTY(read)`
invoke is deferred behind that seam until paideia-os#1986 lands.
See `design/architecture.md` §3.3 for the deferral rationale.
History persistence to `~/.history/` remains ENH-008 (#35) work;
today the encoded HistoryEntry bytes are appended to an in-memory
`.bss` ring so the encoder is exercised end-to-end from the REPL.
Cross-repo linkage (shell → libpdx-cap / libpdx-audit /
libpdx-semantic-pipe symbols) is ENH-009 (#36) work.

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

## Built-in commands (ENH-004)

Four in-process builtins land at ENH-004; the dispatch layer is
`src/dispatch.pdx` and the handler bodies live in `src/builtins.pdx`.
Every handler has signature `(argv_ptr, argc) -> u64`; `dispatch_line`
looks up `argv[0]` against a runtime-loaded table and either calls
the matching handler (returning its result) or returns `BI_MISS =
0xFFFFECE0` so the REPL can try the external command path.

| Name     | Description                                                            |
|----------|------------------------------------------------------------------------|
| `cd`     | Change working directory via real `sys_chdir` (SC+ 85).                |
| `exit`   | Terminate the shell via real `sys_exit` (SC+ 60). Optional decimal code. |
| `export` | Set a **shell-local** variable (see D5 note below).                    |
| `pwd`    | Print the current directory via real `sys_getcwd` (SC+ 86) + `sys_write`. |

**D5 note on `export`.** The shell reads no environment variables
(D5, `design/architecture.md`). `export NAME=VALUE` therefore populates
a **shell-local** variable table (`_bi_env`, cap 32 records / 4096
bytes) that is **NOT inherited by children** -- `sys_execve` does not
receive an `envp`, and the shell does not forward the table. The
table is available for variable expansion at the ENH-006 REPL; it is
never visible outside this shell process. A future "genuine" env
inheritance would land as a distinct KIND (e.g. `KIND_ENV_SLOT`) with
explicit narrowing, not by widening ambient env. This matches the D2
capability-is-the-only-inheritable-authority stance the project has
held since v1.0.0.

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
`svc.login-shell` broker-bind encoder) — never an executable shell.
See [`design/architecture.md`](design/architecture.md),
[`doc/shell.pdxdoc`](doc/shell.pdxdoc), and the pre-R106 CHANGELOG
entries for the full v1.0.0 surface.

The substrate this encoder half was waiting on (KIND_TTY, `sys_execve`
with real argv/envp at R62, `sys_wait4`, `sys_chdir`/`sys_getcwd` at
R86, PdxFS write) has since landed upstream in paideia-os. Wiring that
substrate up in the shell repo is the
`v2.0 — real exec substrate` milestone
([`design/enhancement-plan.md`](design/enhancement-plan.md)); ENH-001..
ENH-006 are landed as of the ENH-006 commit -- lexer, parser, builtin
dispatch table, real exec, and the `Shell::shell_main` entry frame
(declared in `manifest.pdxproj` since M1) now all exist. ENH-007
(line reader body), ENH-008 (history persistence), and ENH-009
(cross-repo linkage) remain open; this milestone is separate from the
R106 tokenizer/scaffold wave above.

## License

MIT — see LICENSE.
