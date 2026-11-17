# Reverse-Engineering Cookbook

**A working manual for the RE toolkit in this repository.**

Every command in this book was run against the installed engine before it was
written down. Where a tool is absent from a machine, the book says so instead
of pretending otherwise.

- Engine: **REA** (`rea` CLI, 198 commands, 255 MCP tools)
- Toolkit scripts: `scripts/re-analyze.sh`, `scripts/env-report.sh`,
  `scripts/skill-sync.sh`, `scripts/lib/*.mjs`
- Generated command list: [`rea-command-catalog.md`](rea-command-catalog.md)

---

## Contents

1. [What this toolkit is](#1-what-this-toolkit-is)
2. [Install and verify](#2-install-and-verify)
3. [The five-minute workflow](#3-the-five-minute-workflow)
4. [Targets by kind](#4-targets-by-kind)
5. [The pipeline in depth](#5-the-pipeline-in-depth)
6. [Writing your own profile](#6-writing-your-own-profile)
7. [Deeper analysis: functions, decompilation, tracing](#7-deeper-analysis)
8. [Working with evidence](#8-working-with-evidence)
9. [Dynamic analysis](#9-dynamic-analysis)
10. [Keeping skill copies consistent](#10-keeping-skill-copies-consistent)
11. [Exporting this book to PDF](#11-exporting-to-pdf)
12. [Limits and honest claims](#12-limits-and-honest-claims)

---

## 1. What this toolkit is

Two layers.

**The engine (REA).** A CLI and MCP server that drives Ghidra, JADX, and other
providers over real artifacts. It classifies, decompiles, searches, traces and
emits *Evidence*: JSON envelopes carrying an `evidence_id`, a `confidence`
level (`observed` / `derived`), an `authority` (`shipped-artifact`) and an
explicit `limitations` list.

**The toolkit (this repo).** The parts REA leaves to you:

| Script | Job |
| --- | --- |
| `scripts/re-analyze.sh` | classify → select inspections → run → capture → report |
| `scripts/lib/detect.mjs` | magic-byte classification, no execution |
| `scripts/lib/report.mjs` | build `summary.json` and `report.md` from evidence |
| `scripts/lib/catalog.mjs` | regenerate the REA command catalog |
| `scripts/env-report.sh` | measure what this machine can actually do |
| `scripts/skill-sync.sh` | keep REA skill copies consistent across harnesses |

The point of the wrapper is repeatability: the same target produces the same
directory of artifacts, so two analysts can compare results, and a CI job can
assert on them.

---

## 2. Install and verify

### 2.1 Engine

```bash
npm i -g rea-agents        # installs the `rea` CLI
rea --version             # expect 6.x
rea doctor --json         # health of every provider
```

`rea doctor` is the source of truth. A healthy Ghidra provider looks like:

```json
{
  "identity": {
    "skill": { "state": "aligned", "installed_version": "62", "installed_tool_count": 255 }
  },
  "providerInspections": [
    { "id": "ghidra", "configured": true, "available": true, "providerVersion": "12.1.4" }
  ]
}
```

If Ghidra is missing:

```bash
rea setup --client pi --skill --yes
```

### 2.2 Toolkit capability report

```bash
bash scripts/env-report.sh
```

This prints a table of every relevant tool with its measured version. It is
also available as `./scripts/re-analyze.sh --doctor`.

Typical output on a Windows workstation (truncated):

| Capability | Present | Detail |
| --- | --- | --- |
| REA engine | yes | `rea@6.9.0` |
| REA providers | yes | ghidra:available, ida:missing, jadx:available, kuna:missing |
| binutils:objdump | yes | `objdump` |
| gdb | yes | `GNU gdb` |
| r2 / radare2 / rizin | no | - |
| binwalk | no | - |
| docker | no | - |
| tshark / wireshark | no | - |
| pandoc | no | - |
| headless browser | yes | Chrome / Edge (PDF export available) |

**Read this table before writing a claim.** With no `binwalk`, a firmware
question goes to `rea inspect-firmware-regions` instead. With no `tshark`, a
network capture question needs `tshark` installed or must be declared
unverifiable.

---

## 3. The five-minute workflow

```bash
# 1. classify + run every applicable inspection + write a report
bash scripts/re-analyze.sh ./suspicious.exe

# 2. read the report
less ./suspicious.exe_analysis/report.md

# 3. machine-readable roll-up
cat ./suspicious.exe_analysis/summary.json
```

That is the whole loop. Everything below is refinement.

---

## 4. Targets by kind

`detect.mjs` reads magic bytes and returns a kind. The kind selects which REA
inspections run.

| Kind | Detected by | Inspections run (standard profile) |
| --- | --- | --- |
| `pe` | `MZ` + `PE\0\0` signature | hardening, PE imports, PE resources, PE certificates, PE load config, native exports, load image, native API, byte entropy, objdump |
| `elf` | `\x7fELF`, class byte gives 32/64-bit | binary layout, hardening, ELF notes, unwind ranges, native exports, load image, native API, byte entropy, objdump |
| `macho` | `MH_MAGIC` / `MH_MAGIC_64` / `FAT_MAGIC` | binary layout, hardening, macho, native exports, load image, native API, byte entropy |
| `go` | Go runtime markers in the head | go-binary, native exports, byte entropy |
| `rust` | `rustc` markers in the head | rust-binary, native exports, byte entropy |
| `managed` | `0xCAFEBABE` class magic | managed-artifact, managed-members, managed-native-boundaries, byte entropy |
| `wasm` | `\0asm` | wasm-artifact, artifact, byte entropy |
| `python_pyc` | extension + marshal header | python-pyc, artifact, byte entropy |
| `apk` | `.apk` / `.aab` extension | android-package, apk-signature, android-jni-bindings |
| `android_dex` | `.dex` extension | android-class, android-method |
| `firmware` | uImage magic / `.bin` `.img` | firmware-regions, kernel-build-config, artifact, byte entropy |
| `sqlite` | `SQLite format 3\0` | sqlite-database, artifact, byte entropy |
| `archive` | `PK\x03\x04`, gzip, bzip2, `ustar` | artifact, byte entropy |
| `image` | PNG / JPEG / GIF / RIFF | artifact, byte entropy |
| `generic` | nothing matched | artifact, byte entropy |

Override detection when it is wrong (headerless firmware, raw CPU dumps):

```bash
bash scripts/re-analyze.sh --kind firmware ./dump.bin
```

For a raw CPU image, REA needs the CPU and entry point supplied explicitly:

```bash
rea analyze ./dump.bin --target-format raw-binary --architecture arm64 --entry-point 0x80000
```

---

## 5. The pipeline in depth

```
detect.mjs ──► kind + sha256 + command list
     │
     ├──► local triage   file, sha256, strings, objdump/nm/readelf
     ├──► rea analyze    overview: segments, procedure_count, string_count
     ├──► rea inspect-*  one step per applicable inspection
     ├──► rea decompile-all   (deep profile only)
     └──► string triage  (when --grep given)
              │
              └──► report.mjs ──► summary.json + report.md
```

### 5.1 Profiles

| Profile | Steps | Typical time (small PE) |
| --- | --- | --- |
| `quick` | overview + first 3 inspections | ~35 s |
| `standard` | overview + all kind inspections | 1–3 min |
| `deep` | standard + `decompile-all` + triage | minutes to hours, size-dependent |

The 35-second figure is measured: `rea analyze` on a 62 KB PE with 144
procedures took ~27 s, dominated by Ghidra cold start.

### 5.2 Output layout

```
<target>_analysis/
├── detect.json          classification + digest
├── summary.json         every step, status, evidence id, digest, facts
├── report.md            human-readable
├── timing.txt           wall-clock seconds
├── steps/
│   ├── rea-analyze.json            REA evidence envelope
│   ├── rea-analyze.log             stderr
│   ├── rea-analyze.status          ok | error | skipped
│   ├── local-file.json             plain local-tool output
│   └── ...
├── decompiled/          pseudocode, deep profile
└── logs/pipeline.log    the run log
```

### 5.3 Options worth knowing

| Option | Effect |
| --- | --- |
| `--out <dir>` | choose the output directory |
| `--profile quick\|standard\|deep` | step depth |
| `--grep 'a,b'` | case-insensitive string triage with hit counts |
| `--extra cmd1,cmd2` | add specific REA operations |
| `--step <regex>` | run only matching steps |
| `--kind <kind>` | override classification |
| `--config <file>` | load a saved profile |
| `--timeout <secs>` | per-command timeout (default 900) |
| `--strict` | stop at the first failure |
| `--allow-exec` | permit steps that run the target |
| `--doctor` | print the capability report and exit |

### 5.4 Exit codes

| Code | Meaning |
| --- | --- |
| 0 | pipeline completed (individual steps may have failed — check `summary.json`) |
| 2 | usage error |
| 3 | target not found |
| 4 | no engine available |

A pipeline that finishes with `error` steps is still exit 0 *by design*: a
missing optional inspection should not fail a CI job. Assert on
`summary.counts.steps_error` when you need strictness.

### 5.5 Worked example

```bash
$ bash scripts/re-analyze.sh --profile quick --grep 'hello,printf' ./hello.exe
[00:43:01] target: /tmp/retest/hello.exe
[00:43:02] detected kind=pe arch=x86_64 sha256=9f7e3c08f9be6fa4…
[00:43:02] engine: 6.9.0
[00:43:29]   ok: rea-analyze
[00:43:30]   ok: rea-inspect-binary-hardening
[00:43:32]   ok: rea-inspect-pe-imports
[00:43:34]   ok: rea-inspect-pe-resources
hello                    5 hits
printf                   12 hits
──────────────────────────────────────────────────────────────
 Target    : hello.exe (pe / x86_64)
 Steps     : 10 ok · 0 error · 0 skipped
 Duration  : 34s
```

---

## 6. Writing your own profile

Profiles are JSON. Save one and pass `--config`.

```json
{
  "profile": "standard",
  "kind": "pe",
  "grep": ["api_key", "password", "secret", "BEGIN RSA", "http://", "https://"],
  "extra": ["inspect-binary-hardening", "inspect-pe-imports"],
  "timeoutSeconds": 600,
  "decompileAll": false,
  "allowExec": false,
  "reportFormats": "json,md"
}
```

A useful triage profile for unknown Windows binaries:

```json
{
  "profile": "deep",
  "grep": [
    "password", "passwd", "api_key", "apikey", "token", "secret",
    "BEGIN PRIVATE KEY", "BEGIN RSA PRIVATE KEY",
    "http://", "https://", "ftp://",
    "\\\\.\\\\pipe\\\\", "cmd.exe", "powershell", "CreateProcess",
    "VirtualAlloc", "WriteProcessMemory", "LoadLibrary", "GetProcAddress",
    "IsDebuggerPresent", "OutputDebugString", "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run"
  ],
  "timeoutSeconds": 1800
}
```

Those patterns are conventional malware-triage indicators. Hitting one is a
lead, not a finding — confirm with `rea function` / `rea decompile` before
claiming behaviour.

---

## 7. Deeper analysis

The pipeline answers "what is this". These answer "what does this specific
thing do".

### 7.1 One function

```bash
rea function ./app.exe --procedure main --format json
rea function ./app.exe 0x140001000 --format json
```

Returns a complete function dossier: entry, body ranges, callees, callers,
strings referenced, and the evidence trail.

### 7.2 Pseudocode

```bash
rea decompile ./app.exe --procedure main --format json
rea decompile ./app.exe --address 0x140001000 --format json
rea decompile ./app.exe --file-offset 0x1000 --format json
```

### 7.3 Every function at once

```bash
rea decompile-all ./app.exe --output ./pseudocode --layout address
```

`--layout dwarf` reports that compilation-unit paths are unavailable; use
`address` unless you have DWARF.

### 7.4 Search

```bash
rea search ./app.exe --pattern 'password' --format json
rea search ./app.exe --pattern '^Crypt[A-Z]' --format json
```

Searches every analyzed string and procedure name. An empty result does not
prove absence — see §12.

### 7.5 References

```bash
rea xrefs ./app.exe --address 0x140005000 --format json
```

### 7.6 Feature tracing

```bash
rea trace ./app.exe --query 'config file' --format json
rea trace-native-values ./app.exe --address 0x140001000 --format json
rea trace-application-feature ./app.exe --query 'login' --format json
```

`trace` follows a literal through analyzed references; the `trace-*` family
does the same for a specific artifact type (native def-use, JS semantics,
dylib resolution, Android references).

### 7.7 Release-exposure audit

```bash
rea audit-release-exposure ./dist/app.exe --format json
rea audit-release-exposure ./dist --fail_on high --format json
```

Answers "what does static analysis recover from this shipped build" — debug
symbols, source maps, embedded sources, private keys. `--fail_on high` exits 3
when a high-severity exposure is found, so it works as a CI gate.

### 7.8 Extraction

```bash
rea extract-artifact ./app.asar --format json
rea extract-firmware ./firmware.bin ./extracted --format json
```

### 7.9 Guided workflows

The engine ships its own playbooks:

```bash
rea guided-workflows                     # list them
rea guidance --query 'electron'          # search the installed guidance
rea capabilities                         # what providers can do, with side effects
rea providers                            # what is configured
```

Read `rea capabilities` before assuming an operation is passive: it documents
side effects per provider.

---

## 8. Working with evidence

Every REA envelope contains:

| Field | Meaning |
| --- | --- |
| `evidence_id` | content-addressed id for this observation |
| `predicate_type` | what kind of statement this is (`rea.analysis`, …) |
| `operation` | the operation that produced it |
| `confidence` | `observed` (read from the artifact) or `derived` (composed) |
| `authority` | `shipped-artifact` — the claim is about the bytes |
| `limitations` | what this observation does *not* establish |
| `digest` | digest of the analysis profile + inputs |

Keep an envelope to re-check later:

```bash
rea evidence-export ./steps/rea-analyze.json ./evidence/analyze.json
rea evidence-import ./evidence/analyze.json
rea compare ./evidence/a.json ./evidence/b.json
```

Two rules when reporting:

1. **Quote `confidence`.** `observed` may be stated plainly; `derived` should
   be described as derived.
2. **Quote `limitations` when they bear on the claim.** Ghidra's "counts use
   the complete defined-string inventory … do not establish discovery of
   undefined strings" is the difference between "no password string found" and
   "there is no password".

---

## 9. Dynamic analysis

Static analysis cannot answer everything. Dynamic steps are opt-in because
they **execute the target**.

### 9.1 Through the pipeline

```bash
bash scripts/re-analyze.sh --allow-exec ./app.exe
```

Runs `gdb -batch -ex 'file …' -ex 'break main' -ex run -ex bt -ex quit`.

### 9.2 Through the engine

```bash
rea debug-with-gdb 'info functions' --format json
rea capture-process ./scenario.json --format json
rea capture-browser-scenario ./scenario.json --format json
rea capture-electron-scenario ./scenario.json --format json
```

### 9.3 Safety

- Never `--allow-exec` an untrusted sample on a host you care about.
- Use a VM or container with no network for malware.
- `rea` will not launch a target for the `inspect-*` family; those are static.

---

## 10. Keeping skill copies consistent

The REA skill is installed by several harnesses. Copies are *not* redundant —
each client needs its own — but they can drift.

```bash
bash scripts/skill-sync.sh --list     # every copy, version, tool count, state
bash scripts/skill-sync.sh --verify   # exit 1 if a copy is behind
bash scripts/skill-sync.sh --sync     # repair via `rea setup` (the supported path)
bash scripts/skill-sync.sh --prune    # show (or --apply) stale copies and backups
```

States reported:

| State | Meaning |
| --- | --- |
| `match` | same instructions as the git source |
| `meta-only` | same version; generated metadata (`tool_count`) differs |
| `SOURCE-AHEAD` | git checkout has newer guidance than the published install |
| `DRIFT` | different instruction body at an older version |
| `absent` | not installed for that client |

**Use `rea setup --skill-client <client> --skill --yes` to repair.** Hand-copying
`SKILL.md` loses the generated `tool_count` metadata and `rea doctor` then
reports the copy as `stale` — verified the hard way while building this
toolkit.

---

## 11. Exporting to PDF

Build the book with whatever this machine has.

```bash
bash scripts/build-docs.sh
```

Which tries, in order:

1. `pandoc` + a LaTeX engine → best typography
2. `pandoc` + `wkhtmltopdf`
3. headless Chrome / Edge `--headless --print-to-pdf` over a rendered HTML page

Option 3 needs nothing installed beyond a browser, which is why it is the
fallback. Run `bash scripts/env-report.sh` to see which path you will get.

The resulting PDF lands in `docs/dist/`.

---

## 12. Limits and honest claims

Reverse engineering is full of statements that are technically true and
practically wrong. This toolkit tries to keep you on the right side.

**What the pipeline proves.** That specific bytes exist, that a specific
header field has a specific value, that a named function exists with these
callees. Those are `observed`.

**What it does not prove.**

| Tempting claim | Why it is wrong |
| --- | --- |
| "No password string, so there is none" | Ghidra inventories *defined* strings. Packed, encrypted, or undefined bytes are invisible. |
| "144 procedures, so the program has 144 functions" | That is the *observed* inventory. Unidentified functions are not counted. |
| "The binary does not call the network" | Imports show statically linked calls. Dynamic loading, syscalls, and injected code are invisible. |
| "Decompiled code is the source" | Pseudocode is a reconstruction. Types, names and control flow may not match what the compiler emitted. |
| "It is not malicious" | Absence of evidence in a static pass is not evidence of absence. |

**What to do instead.** State the observation, name the operation, cite the
`evidence_id`, and say what remains unknown. That is a defensible report;
"looks clean" is not.

---

## Appendix A — Command cheat sheet

See [`RE-CheatSheet.md`](RE-CheatSheet.md) for the one-page version.

## Appendix B — Generated catalog

See [`rea-command-catalog.md`](rea-command-catalog.md), regenerated with:

```bash
node scripts/lib/catalog.mjs docs/rea-command-catalog.md
```

## Appendix C — Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `rea doctor` says skill `stale` | hand-edited skill copy | `rea setup --skill-client shared --skill --yes` |
| `inspect-binary-layout` fails on a PE | layout inspection is ELF-only | expected; the tool records it as an error step, not a crash |
| `readelf` fails on a PE | `readelf` is ELF-only | the pipeline gates it on kind |
| `rea analyze` times out at 900 s | Ghidra cold start on a large binary | raise `--timeout`, or use `--profile quick` |
| Everything fails with 127 | `rea` not on PATH | `export PATH="$PATH:$APPDATA/npm"` |
| PDF build makes Markdown | no pandoc, no browser | install one; `env-report.sh` says which |

---

_This book is part of the re-toolkit. Regenerate the command catalog whenever
the engine is upgraded; the rest is hand-written and reviewed._
