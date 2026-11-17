---
name: reverse-engineering-suite
description: Run a full reverse-engineering workflow on any shipped artifact — native PE/ELF/Mach-O, managed .NET/Java, APK/DEX, WASM, PyC, firmware images, SQLite, archives — using the local RE toolkit and the REA engine (Ghidra/JADX providers). Classifies the target, selects the correct inspections, decompiles, triages strings, and writes an evidence-backed report. Use when asked to reverse engineer, decompile, unpack, audit the exposure of, or triage an unknown binary or package, or to explain what a shipped artifact does. Skip for ordinary source-repository architecture analysis.
metadata:
  version: "1"
  toolkit: re-toolkit
---

# Reverse-Engineering Suite

A programmable pipeline over the **REA** engine (`rea` CLI / MCP server, 196 CLI
commands, 255 MCP tools) plus local binutils. The suite adds the parts REA does
not do for you: target classification, command selection, evidence capture,
triage and a written report.

## When to use this skill

Use it when the question depends on a **shipped artifact** rather than on
source you already have:

- "What does this EXE do?" / "reverse engineer this binary"
- "Is there anything exposed in this release build?"
- "Unpack this APK / decompile this .NET DLL / read this .pyc"
- "Find the hard-coded key in this firmware image"
- "What network endpoints does this client talk to?"

Do **not** use it for a source repository you can simply read; normal
repository tools are faster and more accurate there.

## Preconditions

1. The REA engine is installed and healthy:

   ```bash
   rea doctor --json        # expect skill=aligned, ghidra=available
   ```

   If Ghidra is missing, run `rea setup --client pi --skill --yes` (or
   `rea setup --install-ghidra`). Do not silently continue without an
   engine — say what is missing.

2. The toolkit scripts are on disk. This skill expects them under
   `<repo>/scripts/`. If `scripts/re-analyze.sh` is not found, ask the
   operator for the toolkit path instead of improvising a different pipeline.

## Workflow

### Step 0 — Capability check (always, once)

```bash
bash <repo>/scripts/env-report.sh
```

Report what is available. Missing engines (Hopper, IDA, Kuna) change what you
may claim: with only Ghidra you can say *observed*, not *exhaustive*.

### Step 1 — Classify the target

```bash
node <repo>/scripts/lib/detect.mjs <target>
```

Gives kind, format, architecture, SHA-256 and the inspection commands that
apply. Magic-byte detection only — the target is never executed.

### Step 2 — Run the pipeline

```bash
bash <repo>/scripts/re-analyze.sh --profile standard --out <outdir> <target>
```

Profiles:

| Profile | What runs |
| --- | --- |
| `quick` | detection, overview, 3 kind-specific inspections |
| `standard` | detection, overview, every kind-specific inspection |
| `deep` | standard + `decompile-all` + string triage |

Useful extras:

```bash
--grep 'api_key,password,token'   # string triage
--extra inspect-binary-hardening  # add one REA operation
--config ./profiles/app.json       # a saved profile (see docs/RE-Cookbook.md)
--allow-exec                       # permit gdb-backed dynamic steps
```

**Never pass `--allow-exec` for an untrusted target without telling the
operator it will run the binary.**

### Step 3 — Read the evidence, then write the report

Artifacts land in `<outdir>`:

```
<outdir>/detect.json        classification
<outdir>/steps/*.json       one REA envelope per step
<outdir>/steps/*.log        stderr per step
<outdir>/summary.json       machine-readable roll-up
<outdir>/report.md          human-readable report
<outdir>/decompiled/        pseudocode (deep profile)
```

Read `summary.json` and `report.md`. Each step carries `evidence_id`,
`confidence`, `authority` and `limitations`. Quote limitations when you make
claims — REA's own limitation text is part of the evidence, not noise.

### Step 4 — Deeper answers (only if the question needs them)

```bash
rea function <target> --procedure <name> --format json     # one function
rea decompile <target> --procedure <name> --format json     # pseudocode
rea search <target> --pattern <regex> --format json        # string/proc search
rea xrefs <target> --address 0x140001000 --format json      # references
rea trace <target> --query <feature> --format json          # feature trace
rea audit-release-exposure <target> --format json            # exposure audit
```

Prefer `rea function` / `rea decompile` over reading raw Ghidra output: they
return the same evidence as MCP calls, with provenance attached.

### Step 5 — Report

Give the operator, in this order:

1. **What the target is** — format, architecture, digest, how it was classified.
2. **What it does** — the evidence-backed summary (imports, exports, strings,
   hardening, resources).
3. **What stands out** — hardening gaps, embedded secrets, interesting
   endpoints, debug leftovers.
4. **What you could not determine** — limitations, failed steps, missing engines.
5. **Where the artifacts are** — the output directory and the files in it.

Cite the evidence id for anything you assert. If a step failed, say so and
say why; do not paper over it.

## Rules

- **Evidence over inference.** Every claim maps to a step, an evidence id, or a
  local tool output that you can point at.
- **Report limitations.** REA attaches them to every envelope; they are part of
  the result.
- **Do not execute unknown binaries** unless the operator asked for dynamic
  analysis and understands the risk.
- **Do not claim completeness.** `analyze` reports observed inventories;
  empty results do not prove absence of strings or functions.
- **One target per run.** Directory and bundle targets are supported, but a
  run's report is about one subject.

## Reference

- `docs/RE-Cookbook.md` — the full manual: every workflow, every command, the
  config-file format, and the PDF export.
- `docs/RE-CheatSheet.md` — one-page command reference.
- `scripts/skill-sync.sh` — keep the REA skill copies consistent across
  harnesses (`--list`, `--verify`, `--sync`, `--prune`).
