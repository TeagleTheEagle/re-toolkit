# Reverse-Engineering Cheat Sheet

One page. Every command verified against the installed engine.

## Classify without executing

```bash
node scripts/lib/detect.mjs <target>          # kind, arch, sha256, planned steps
file <target>; strings -a -n 6 <target> | head -50
sha256sum <target>                            # shasum -a 256 / openssl dgst -sha256
```

## Run the pipeline

```bash
bash scripts/re-analyze.sh <target>                        # standard
bash scripts/re-analyze.sh --profile quick <target>        # fast look
bash scripts/re-analyze.sh --profile deep --grep 'key,token' <target>
bash scripts/re-analyze.sh --config profiles/windows-triage.json <target>
bash scripts/re-analyze.sh --out /tmp/run1 --strict <target>
```

## Engine: the ten you need

| Task | Command |
| --- | --- |
| Overview | `rea analyze <t> --format json` |
| List/read one function | `rea function <t> --procedure <name> --format json` |
| Pseudocode | `rea decompile <t> --procedure <name> --format json` |
| All pseudocode | `rea decompile-all <t> --output <dir>` |
| Search strings/procs | `rea search <t> --pattern <regex> --format json` |
| References to an address | `rea xrefs <t> --address 0x… --format json` |
| Trace a feature | `rea trace <t> --query <text> --format json` |
| Release exposure | `rea audit-release-exposure <t> --format json` |
| Capabilities/side effects | `rea capabilities` |
| Health | `rea doctor --json` |

## By artifact kind

```bash
# PE (Windows)
rea inspect-binary-hardening app.exe --format json
rea inspect-pe-imports app.exe --format json
rea inspect-pe-resources app.exe --format json
rea inspect-pe-certificates app.exe --format json

# ELF (Linux)
rea inspect-binary-layout lib.so --format json      # ELF/object only
rea inspect-elf-notes lib.so --format json
rea inspect-elf-unwind-ranges lib.so --format json

# Mach-O (macOS)
rea inspect-macho App.app --format json

# Language runtimes
rea inspect-go-binary tool --format json
rea inspect-rust-binary tool --format json
rea inspect-managed-artifact app.dll --format json
rea inspect-wasm-artifact mod.wasm --format json
rea inspect-python-pyc mod.pyc --format json

# Mobile
rea inspect-android-package app.apk --format json
rea inspect-apk-signature app.apk --format json
rea inspect-android-jni-bindings app.apk --format json

# Firmware / embedded
rea inspect-firmware-regions fw.bin --format json
rea inspect-kernel-build-config vmlinux --format json
rea extract-firmware fw.bin ./out --format json

# Containers / packaged
rea inspect-artifact app.asar --format json
rea extract-artifact app.asar --format json
rea inspect-electron-fuses app.exe --format json
```

## Triage patterns that pay off

```
password  passwd  api_key  apikey  secret  token
BEGIN PRIVATE KEY   BEGIN RSA PRIVATE KEY   BEGIN OPENSSH PRIVATE KEY
http://  https://  ftp://  wss://
cmd.exe  powershell  /bin/sh  CreateProcess  WinExec  ShellExecute
VirtualAlloc  WriteProcessMemory  LoadLibrary  GetProcAddress
IsDebuggerPresent  OutputDebugString  CheckRemoteDebuggerPresent
CurrentVersion\\Run  schtasks  .onion
```

A hit is a lead. Confirm with `rea function` / `rea decompile` before claiming
behaviour.

## Evidence discipline

```bash
# every envelope carries these — quote them
evidence_id   confidence (observed | derived)   authority   limitations

rea evidence-export <envelope.json> <bundle.json>
rea evidence-import <bundle.json>
rea compare <a.json> <b.json>
```

- `observed` → state plainly. `derived` → say "derived".
- Empty string search ≠ no strings. Undefined/packed bytes are invisible.
- `procedure_count` is the *observed* inventory, not the true function count.

## Output control

```bash
rea <cmd> <t> --format json --filter-output normalized_result.segments
rea <cmd> <t> --format json --token-limit 4000
rea <cmd> <t> --format json --full-output
rea <cmd> <t> --schema          # exact JSON schema for this command
```

## Maintenance

```bash
bash scripts/env-report.sh                  # what can this machine do?
bash scripts/skill-sync.sh --verify         # skill copies consistent?
bash scripts/skill-sync.sh --sync           # repair via rea setup
node scripts/lib/catalog.mjs docs/rea-command-catalog.md
```

## Gotchas that cost time

| Symptom | Answer |
| --- | --- |
| `inspect-binary-layout` fails on PE | ELF-only by design |
| `readelf` fails on PE | ELF-only; the pipeline gates it |
| Skill shows `stale` after editing | repair with `rea setup --skill-client shared --skill --yes`, not `cp` |
| `rea: command not found` | `export PATH="$PATH:$APPDATA/npm"` |
| Ghidra timeout | raise `--timeout`, or `--profile quick` |
| Headless profile discards annotations | set `REA_GHIDRA_CHECKPOINT_DIR` before starting REA |
