# Reverse-Engineering Wiki

> The team entry point for reverse-engineering work. Start here, then follow
> the links.

## Start here

| If you want to… | Go to |
| --- | --- |
| Analyse a binary right now | [Quick start](#quick-start) |
| Learn the whole toolkit | [Cookbook](docs/RE-Cookbook.md) ([PDF](docs/dist/RE-Cookbook.pdf)) |
| Look up a command | [Cheat sheet](docs/RE-CheatSheet.md) ([PDF](docs/dist/RE-CheatSheet.pdf)) |
| Know what a command does | [Command catalog](docs/rea-command-catalog.md) |
| Teach this to the team | [Workshop agenda](workshop/AGENDA.md) |

## Quick start

```bash
npm i -g rea-agents                      # the engine (once)
rea doctor --json                        # confirm a provider is available
bash scripts/env-report.sh               # what this machine can do

bash scripts/re-analyze.sh target.bin    # analyse anything
less target.bin_analysis/report.md       # read the result
```

## What the toolkit covers

| Artifact | What the pipeline runs |
| --- | --- |
| Windows PE | hardening, imports, resources, certificates, load config, exports, load image, entropy |
| Linux ELF | layout, hardening, ELF notes, unwind ranges, exports, load image, entropy |
| macOS Mach-O | layout, hardening, Mach-O specifics, exports, entropy |
| Go / Rust | build metadata, exports, entropy |
| .NET / Java | managed artifact, members, native boundaries |
| APK / DEX | package, signature, JNI bindings |
| WASM / PyC | interface, header, marshal objects |
| Firmware | regions, kernel build config, verified extraction |
| Archive / image / SQLite | inventory, entropy, schema |

## Three rules

1. **Evidence over inference.** Every claim cites a step or an `evidence_id`.
2. **Report limitations.** REA attaches them to every envelope; they are part
   of the result, not noise.
3. **Do not run unknown binaries.** `inspect-*` is static. Dynamic steps need
   `--allow-exec` and a VM.

See [Limits and honest claims](docs/RE-Cookbook.md#12-limits-and-honest-claims)
before you write a report.

## Common tasks

### Is this release build leaking anything?

```bash
rea audit-release-exposure ./dist --fail_on high --format json
```

Exits 3 when a high-severity exposure is found — usable as a CI gate.

### What does this function do?

```bash
rea function  ./app.exe --procedure main --format json
rea decompile ./app.exe --procedure main --format json
```

### Where is this string used?

```bash
rea search ./app.exe --pattern 'password' --format json
rea xrefs  ./app.exe --address 0x140005000 --format json
```

### Is my installed skill current?

```bash
bash scripts/skill-sync.sh --verify     # exit 1 when a copy is behind
bash scripts/skill-sync.sh --sync       # repair via `rea setup`
```

Hand-copying `SKILL.md` is *not* equivalent: it drops the generated
`tool_count`, and `rea doctor` then reports the copy as `stale`. Always use
`rea setup --skill-client <client> --skill --yes`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `rea: command not found` | not on PATH | `export PATH="$PATH:$APPDATA/npm"` |
| skill state `stale` | hand-edited copy | `rea setup --skill-client shared --skill --yes` |
| `inspect-binary-layout` errors on PE | ELF-only operation | expected; other PE inspections still run |
| `readelf` errors on PE | ELF-only tool | the pipeline gates it on kind |
| `nm` reports "no symbols" | stripped binary | recorded as a finding, not a failure |
| analysis times out | Ghidra cold start | raise `--timeout`, or use `--profile quick` |
| steps error on a tiny fake binary | truncated/headerless input | supply `--kind`, `--target-format`, `--architecture` |

## Contributing

- **New inspections**: add the command to `KIND_COMMANDS` in
  `scripts/lib/detect.mjs` and to the table in `scripts/re-analyze.sh`.
- **New profiles**: drop a JSON file in `profiles/`; document it in the cookbook.
- **Tests**: `bash tests/test-toolkit.sh` must pass. Add a case for anything
  new — a check that cannot fail is not a check.
- **Docs**: regenerate the catalog with
  `node scripts/lib/catalog.mjs docs/rea-command-catalog.md` and rebuild the
  PDFs.

## Ownership

| Area | Owner |
| --- | --- |
| Toolkit scripts | _(assign)_ |
| Engine upgrades + catalog regeneration | _(assign)_ |
| Workshop delivery | _(assign)_ |

_Engine version this page was verified against: `rea@6.9.0`, Ghidra 12.1.4,
skill v62 / 255 tools._
