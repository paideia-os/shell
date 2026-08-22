# shell — .pdxdoc source-file conventions

**Wave:** R49 (Wave 1)  **Milestone:** M5-002  **Issue:** #16
**Upstream design:** [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
I7 (help + tutorial + example-gallery required per tool);
[`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.3 doc.M1-002 line (`.pdxdoc` file-format parser).

## 0. What this document pins

The exact section markers and value conventions
`doc/shell.pdxdoc` uses, so that the doc.M1-002 parser (landing
in the `doc` repo at end of R49) can render it without a schema
negotiation. This is the SOURCE-side spec; the WIRE spec (byte
layout of the compiled `.pdxdoc` the parser consumes if it ever
compiles) lives in the `doc` repo.

At M5-002 the shell ships the source form; the doc parser's M1
reads exactly this text form. When doc.M2+ introduces a compiled
layer, the source form here is the authoring surface and the
compiled layer sits between it and the reader — the source stays
stable across the compilation step.

## 1. File shape

A `.pdxdoc` file is UTF-8 plain text with `\n` line endings and
NO trailing whitespace on any line. The file opens with a
front-matter block delimited by `---`, followed by a body of
`##`-prefixed sections.

```
---
name: <tool name>
version: <semver>
kind: <tool | library | service>
authors: <comma-separated names or org>
license: <SPDX id>
---

## SYNOPSIS
...

## DESCRIPTION
...

## <SECTION>
...
```

The front-matter block is REQUIRED. The body must contain at
least a `SYNOPSIS` section and a `DESCRIPTION` section; other
sections are optional and appear in the order the tool author
chooses (the doc renderer preserves order rather than
canonicalising).

## 2. Front-matter fields

| Key       | Required | Value shape                                     |
|-----------|----------|-------------------------------------------------|
| `name`    | yes      | tool name (matches `manifest.pdxproj` `name =`) |
| `version` | yes      | semver (matches `manifest.pdxproj` `version =`) |
| `kind`    | yes      | one of `tool` / `library` / `service`           |
| `authors` | yes      | free-form UTF-8                                  |
| `license` | yes      | SPDX identifier                                  |

The parser tolerates lines in front-matter order-insensitively;
the required-key check is done after the block is read.

## 3. Body sections (recommended order)

The tooling wave's shipped tools follow this section order (the
doc renderer's default layout expects it; a tool that deviates
is not rejected but may render awkwardly):

1. **`SYNOPSIS`** — one-line invocation summary followed by
   representative concrete invocations (each on its own line,
   indented by two spaces).
2. **`DESCRIPTION`** — the paragraph-length prose that describes
   what the tool does, why it exists, and where it fits in the
   paideia-os graph.
3. **`OPTIONS`** — flag/argument table. One entry per flag; long
   form primary, short form (if any) in parentheses; typed
   arguments in `<...>` brackets.
4. **`EXAMPLES`** — the ~10 concrete example invocations
   `<tool> --examples` also emits (see plan.md I7 §4). Two spaces
   of indent for the shell prompt and command; blank line between
   entries.
5. **`FILES`** — the on-disk state the tool touches. One path per
   line with a two-sentence explanation.
6. **`ENVIRONMENT`** — env vars the tool reads. paideia-os tools
   should minimise env-var reliance (see plan.md D5); if the
   section is empty, omit it.
7. **`EXIT_STATUS`** — the exit codes the tool emits, per
   plan.md I4 (0 success; 1 caller error; 2 usage; 3 system
   error; 4 capability denied).
8. **`DIFFERENCES_FROM_POSIX`** — one bullet per behavioural
   correction against the POSIX ancestor. Every correction is a
   design decision; the plan.md D2 rationale ("POSIX is a
   starting point, not a contract") applies here.
9. **`SEE_ALSO`** — cross-references to sibling tools and library
   docs. One entry per line as `<name>(<kind>)` where `<kind>` is
   `tool`, `library`, or `design` (a link into a design doc).
10. **`CAPABILITIES_REQUESTED`** — the caps this tool declares in
    its `caps.decl`. Duplicated here so a reader of `doc <tool>`
    sees the cap footprint without opening the source repo.
11. **`SIGNING`** — the two ML-DSA-65 fingerprints
    (`author_pk`, `paideia_root_pk`) that shipped this version's
    `manifest.pdxsig`. Lets a reader cross-check a local install
    against the fingerprints `pkg keys` reports.

Section headers are `##`-prefixed on their own line, uppercase
snake case (spaces → underscores). The doc renderer treats the
prefix and case as significant — a section named `## Synopsis` is
NOT recognised as SYNOPSIS.

## 4. Cross-references

Inline cross-references use `[<label>](<target>)`. The `<target>`
is one of:

- `<tool>(1)` — sibling tool doc (rendered by `doc <tool>`).
- `<library>(3)` — sibling library doc.
- `<file>(5)` — a paideia-os file-format spec.
- `design://<path>` — a link into the `design/` tree of the tool's
  repo.

The trailing `(1)` / `(3)` / `(5)` follow the man-page section
number convention (tools / library funcs / file formats). The
doc.M2 renderer treats these as hotkey-follow-able jumps
(`design/tooling/r49-r50-plan.md` §5.3 M2 line "cross-reference
navigation").

## 5. POSIX-difference annotations

Each `DIFFERENCES_FROM_POSIX` bullet is a single line of the form:

```
- <deviation summary> — <POSIX behaviour> — <paideia-os behaviour>.
```

The three em-dash-separated segments are the render's layout: the
first is bold, the second italic, the third plain. Renderers
that don't support styling render the three segments back-to-back
separated by en-dashes.

## 6. Encoding notes

- UTF-8 throughout; no BOM.
- No tab characters — indent uses two spaces.
- No trailing whitespace on any line.
- Section body paragraphs wrap at 72 columns; the doc renderer
  reflows to the terminal width but the source-form wrap makes
  diff review readable.
- Code blocks use `` ``` `` fences. The opening fence may name a
  language for future syntax highlighting (`.pdx`, `.pds`,
  `sh`); the M1 renderer ignores the annotation.
