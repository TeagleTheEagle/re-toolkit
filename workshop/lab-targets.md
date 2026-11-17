# Lab Targets

The workshop runs on targets that are safe to execute, safe to fail on, and
legal to analyse. **Never distribute live malware in a workshop.**

## What to prepare

| # | Target | Where it comes from | Used in |
| --- | --- | --- | --- |
| 1 | `hello.exe` — a 3-line C program | built in the lab with gcc | Lab 3 (pipeline) |
| 2 | `toy-<n>.exe` — 3 variants with different traits | built from the sources below | Lab 1, 2, 6 |
| 3 | A legitimate open-source CLI binary | build a small tool from source, e.g. `jq`, `ripgrep`, `busybox` | Lab 3, Track work |
| 4 | A packaged app | an Electron or .NET app you build yourself | Electron / .NET track |
| 5 | A firmware image | a public OpenWrt image, or a `.bin` you build | Firmware track |

Everything below is generated locally, so the lab has no supply-chain risk.

## Build the fixtures

```bash
mkdir -p targets && cd targets

# 1. baseline
cat > hello.c <<'EOF'
#include <stdio.h>
int main(int argc, char **argv) {
    printf("hello %d\n", argc);
    return 0;
}
EOF
gcc -g -O0 -o hello.exe hello.c

# 2. variant A: an embedded string that looks like a credential
cat > toy-secret.c <<'EOF'
#include <stdio.h>
static const char *cfg = "PASSWORD=hunter2";   /* a lab decoy, not a real secret */
int main(void) { puts(cfg); return 0; }
EOF
gcc -O0 -o toy-secret.exe toy-secret.c

# 3. variant B: stripped, so symbols are absent
cat > toy-stripped.c <<'EOF'
#include <stdio.h>
#include <string.h>
int check(const char *s) { return strcmp(s, "letmein") == 0; }
int main(int argc, char **argv) {
    if (argc > 1 && check(argv[1])) puts("ok");
    return 0;
}
EOF
gcc -O2 -s -o toy-stripped.exe toy-stripped.c

# 4. variant C: an obvious endpoint, for the triage exercise
cat > toy-endpoint.c <<'EOF'
#include <stdio.h>
int main(void) {
    printf("contact: https://example.invalid/api/v1/report\n");
    return 0;
}
EOF
gcc -O0 -o toy-endpoint.exe toy-endpoint.c
```

On Linux the same sources produce ELF targets, which is better for the ELF
track.

## Sanity check before the workshop

```bash
for f in targets/*; do
  case "$f" in *.c) continue ;; esac
  echo "== $f"
  node ../scripts/lib/detect.mjs "$f" | head -6
done
```

Expect: `hello.exe` and `toy-*.exe` → `pe`; anything built on Linux → `elf`.

## What each variant teaches

| Variant | Lesson |
| --- | --- |
| `hello.exe` | the pipeline end-to-end on a binary you know the source of — the report can be checked against ground truth |
| `toy-secret.exe` | string triage finds a "credential"; **the lesson is that finding a string is not finding a vulnerability** |
| `toy-stripped.exe` | `nm` reports no symbols, the pipeline records that as a finding, and function recovery still works through Ghidra |
| `toy-endpoint.exe` | endpoint extraction as a lead, to be confirmed by reading the function |

## The lesson behind variant B

`toy-stripped.exe` is the most important target in the workshop. Its report
demonstrates three things at once:

1. A missing symbol table is **recorded**, not treated as a failure.
2. Function recovery still works — the analysis does not depend on symbols.
3. `strcmp` against a literal is visible in the decompiled `check`, which is how
   you prove the comparison rather than guessing it from the strings.

## Do not use

- Real malware samples, even "old" ones
- Anything from a client or from production
- Anything you cannot prove you are authorized to examine
- Packed or obfuscated samples — they teach frustration, not method

If a participant asks to analyse something from their own work, apply the same
rule the invitation states: a build they produced, or code they are authorized
to examine in writing.
