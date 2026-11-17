# Documentation

| Document | What it is |
| --- | --- |
| [RE-Cookbook.md](RE-Cookbook.md) | The manual: every workflow, every option, the honest-limits section |
| [RE-CheatSheet.md](RE-CheatSheet.md) | One-page command reference |
| [rea-command-catalog.md](rea-command-catalog.md) | Generated list of every REA command on the installed engine |
| [dist/](dist/) | PDF builds of the above |

## Building the PDFs

```bash
bash scripts/build-docs.sh --list   # which engine will be used
bash scripts/build-docs.sh          # build everything
```

The build picks the best available engine:

1. `pandoc` + LaTeX — best typography
2. `pandoc` + `wkhtmltopdf`
3. headless Chrome or Edge — needs nothing but a browser

Check what your machine will use with `bash scripts/env-report.sh`.

On this workstation there is no `pandoc`, so path 3 is used: Chrome headless
`--print-to-pdf` over a styled HTML page. Output measured at 5 pages
(cheat sheet), 16 pages (cookbook) and 16 pages (catalog).

## Regenerating the catalog

The catalog is generated from the installed engine, so it cannot drift:

```bash
node scripts/lib/catalog.mjs docs/rea-command-catalog.md
```

CI warns when the committed catalog is stale against `rea-agents@latest`.

## Writing style for these docs

- Every command shown has been run. If a tool is missing on the documented
  machine, the doc says so.
- Every claim about a target is framed as an observation with a citation, or
  explicitly marked unknown.
- Version-specific behaviour (the 198 commands, the `aligned` skill state) is
  tied to a measured engine version, not asserted in the abstract.
