# Reverse-Engineering Toolkit

A programmable reverse-engineering pipeline for **any** shipped artifact, built
on the [REA](https://github.com/morluto/rea) engine.

```bash
bash scripts/re-analyze.sh ./suspicious.exe
less ./suspicious.exe_analysis/report.md
```

That is the whole idea: one command, a classified target, every applicable
inspection, and an evidence-backed report — with the artifacts kept so the
result can be checked or re-run.

---

## Why

REA is excellent at *individual* analysis operations. Answering "what is this
binary" still means choosing the right operations, keeping the evidence, and
writing something a colleague can read. This toolkit does that part.

| | |
| --- | --- |
| **Classify** | magic-byte detection; the target is never executed |
| **Select** | only the inspections that apply to that artifact kind |
| **Capture** | every REA evidence envelope, log and status per step |
| **Report** | `report.md` for people, `summary.json` for CI |
| **Verify** | 39 self-tests, no network needed |

---

## Install

```bash
npm i -g rea-agents        # the engine
rea doctor --json          # confirm a provider is available

bash scripts/env-report.sh # what this machine can actually do
bash tests/test-toolkit.sh # 39 checks, ~20 s
```

REA needs a deep-analysis provider for the `rea analyze` step (Ghidra is what
`rea setup` installs). Without one, the pipeline still runs detection, local
binutils triage and reporting, and marks the engine steps as skipped.

---

## Usage

```bash
# standard pass
bash scripts/re-analyze.sh target.exe

# fast look
bash scripts/re-analyze.sh --profile quick target.exe

# deep pass with secret/endpoint triage
bash scripts/re-analyze.sh --profile deep \
     --grep 'password,api_key,https://,cmd.exe' target.exe

# saved profile
bash scripts/re-analyze.sh --config profiles/windows-triage.json target.exe

# override a wrong classification (headerless firmware, raw CPU dump)
bash scripts/re-analyze.sh --kind firmware dump.bin
```

Output:

```
<target>_analysis/
├── detect.json      classification + digest
├── summary.json     every step with status, evidence id, facts
├── report.md        human-readable report
├── steps/           raw envelopes, logs, status per step
└── decompiled/      pseudocode (deep profile)
```

Full manual: **[docs/RE-Cookbook.md](docs/RE-Cookbook.md)**
One-page reference: **[docs/RE-CheatSheet.md](docs/RE-CheatSheet.md)**
Command catalog: **[docs/rea-command-catalog.md](docs/rea-command-catalog.md)**
PDFs: build with `bash scripts/build-docs.sh` → `docs/dist/`

---

## What it handles

| Kind | Inspections |
| --- | --- |
| PE | hardening, imports, resources, certificates, load config, exports, load image, native API, entropy |
| ELF | layout, hardening, notes, unwind ranges, exports, load image, native API, entropy |
| Mach-O | layout, hardening, macho, exports, load image, native API, entropy |
| Go / Rust | language-specific metadata, exports, entropy |
| Managed (.NET/Java) | managed artifact, members, native boundaries |
| WASM / PyC | wasm interface, pyc header + marshal objects |
| APK / DEX | package, signature, JNI bindings |
| Firmware | regions, kernel build config, extraction |
| Archive / image / SQLite | artifact inventory, entropy, schema |

---

## Layout

```
scripts/
  re-analyze.sh        the pipeline
  env-report.sh        capability report
  skill-sync.sh        keep REA skill copies consistent
  build-docs.sh        markdown -> PDF
  lib/detect.mjs       classification
  lib/report.mjs       report generation
  lib/md2html.mjs      dependency-free markdown renderer
  lib/catalog.mjs      regenerate the command catalog
tests/test-toolkit.sh  39 checks
.pi/skills/            composite Pi skill
docs/                  cookbook, cheat sheet, catalog, PDFs
workshop/              2-day agenda + lab runner
```

---

## Safety

- `inspect-*` operations are static; they never launch the target.
- Dynamic steps require `--allow-exec`, because they execute the artifact.
- Do not run untrusted samples outside a VM or container.

## Honest limits

The toolkit reports **observations**, not verdicts. An empty string search does
not mean no strings; `procedure_count` is the observed inventory, not the true
function count. Every REA envelope carries a `limitations` list, and the report
keeps it — see §12 of the cookbook.

## License

Internal tooling. REA itself is governed by its own license.
