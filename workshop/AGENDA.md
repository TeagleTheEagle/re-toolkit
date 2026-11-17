# Two-Day Reverse-Engineering Workshop

A hands-on session for engineers who will use this toolkit. Every lab runs
against a target that is safe to execute and safe to fail on.

- **Audience:** 8–16 engineers, mixed background
- **Prerequisites:** laptop with admin rights, Docker Desktop or the ability to
  run a VM, Node 20+
- **Deliverables:** working toolkit on every laptop, one completed report per
  participant, a shared findings doc

---

## Before the day (T-7)

Send this to every participant.

| # | Task | Command |
| --- | --- | --- |
| 1 | Install Node 20+ | `node --version` |
| 2 | Install the engine | `npm i -g rea-agents` |
| 3 | Run setup | `rea setup --client pi --skill --yes` |
| 4 | Confirm health | `rea doctor --json` → `skill.state: aligned` |
| 5 | Clone the toolkit | `git clone <repo> && cd re-toolkit` |
| 6 | Install binutils | Linux: `apt install binutils file`<br>Windows: `choco install mingw` |
| 7 | Self-test | `bash tests/test-toolkit.sh --fast` → all pass |

If step 4 fails, that is the only blocker worth escalating — everything else
degrades gracefully.

Each participant also downloads the three lab targets (see `lab-targets.md`).
**Do not distribute live malware.** Use these instead:

- a legitimate open-source binary (a small CLI tool built from source)
- a purpose-built vulnerable toy binary
- a packaged app (Electron or .NET) from a public release page

---

## Day 1 — Foundations

### 09:00–09:30 · Welcome, scope, and the law

- What reverse engineering is and is not
- Authorization: what you must have in writing before you analyse anything
- The three claims you may never make (see §12 of the cookbook)

**Outcome:** everyone knows the boundary before touching a binary.

### 09:30–10:30 · Reading a binary without running it

| Concept | Demonstrated with |
| --- | --- |
| Format identification | `file`, `node scripts/lib/detect.mjs` |
| Headers and sections | `objdump -x`, `readelf -a` |
| Strings as a first signal | `strings -a -n 6` |
| Entropy and packing | `rea inspect-byte-entropy` |

**Lab 1:** classify three unknown files. For each, write down the format,
architecture, and one thing you *cannot* tell from headers alone.

### 10:30–10:45 · Break

### 10:45–12:15 · Static analysis at depth

| Concept | Demonstrated with |
| --- | --- |
| Overview and inventory | `rea analyze` |
| Imports as capability | `rea inspect-pe-imports` |
| Hardening posture | `rea inspect-binary-hardening` |
| Function reads | `rea function`, `rea decompile` |
| Reference chasing | `rea xrefs`, `rea trace` |

**Lab 2:** find the function that prints the program's version banner. Report
its address, its callees, and the evidence id you relied on.

### 12:15–13:15 · Lunch

### 13:15–14:45 · The pipeline

```bash
bash scripts/re-analyze.sh --profile standard --out ./lab2 target
```

Walk the output tree together: `detect.json` → `steps/` → `summary.json` →
`report.md`.

**Lab 3:** run the standard profile on your assigned target and hand the
`report.md` to the person next to you. They have five minutes to explain the
target back to you using only that report.

*Discussion:* what was missing from the report? That gap is the specification
for the next profile you write.

### 14:45–15:00 · Break

### 15:00–16:30 · Writing a profile

```json
{
  "profile": "standard",
  "grep": ["password", "token", "https://", "cmd.exe"],
  "extra": ["inspect-pe-imports"],
  "timeoutSeconds": 600
}
```

**Lab 4:** write a profile for your team's most common target type. Run it.
Trim the patterns that produced noise; keep the ones that produced leads.

### 16:30–17:00 · Day 1 close

Each participant states one thing they can now do that they could not this
morning, and one thing they still cannot.

---

## Day 2 — Depth and judgement

### 09:00–10:15 · Dynamic analysis, safely

- What static analysis structurally cannot see
- `rea debug-with-gdb`, `rea capture-process`
- The `--allow-exec` gate and why it exists

**Lab 5:** in a VM with no network, run the pipeline with `--allow-exec` on the
toy binary. Capture a backtrace. Compare it against the static call graph.

*Rule for the room:* nothing leaves the VM.

### 10:15–10:30 · Break

### 10:30–11:45 · Evidence discipline

| Concept | Where it shows up |
| --- | --- |
| `confidence: observed` vs `derived` | every envelope |
| `limitations` | every envelope |
| Reproducibility | same target, same output tree |
| Export and compare | `rea evidence-export`, `rea compare` |

**Lab 6 — the red-team exercise.** Each pair is given a deliberately
*ambiguous* report and asked to find the three claims it cannot support. This is
the most valuable hour of the workshop: it teaches scepticism about your own
output.

### 11:45–12:45 · Lunch

### 12:45–14:15 · Platform specialisations

Pick two tracks based on team need.

| Track | Commands |
| --- | --- |
| **Windows / .NET** | `inspect-pe-*`, `inspect-managed-artifact`, `inspect-managed-members` |
| **Linux / containers** | `inspect-binary-layout`, `inspect-elf-*`, `inspect-artifact` |
| **Mobile** | `inspect-android-package`, `inspect-apk-signature`, `inspect-android-jni-bindings` |
| **Firmware** | `inspect-firmware-regions`, `inspect-kernel-build-config`, `extract-firmware` |
| **Electron / web** | `inspect-electron-fuses`, `analyze-javascript-application`, `recover-javascript-sources` |
| **Release auditing** | `audit-release-exposure --fail_on high` |

### 14:15–14:30 · Break

### 14:30–16:00 · Capstone

Teams of three. Each team gets one target and one question:

> *"What would you tell a product owner about this binary?"*

Deliverable: a one-page report with three findings, each citing an evidence id,
and one explicit statement of what remains unknown.

**Marking rubric:**

| Criterion | Weight |
| --- | --- |
| Every claim cites evidence | 40% |
| Limitations stated honestly | 30% |
| Report readable by a non-specialist | 20% |
| Reproducible (someone else can re-run your profile) | 10% |

### 16:00–16:30 · Retro and next steps

- Which profiles should become team defaults?
- Which inspections were noisy? File issues against the toolkit.
- Who owns keeping the engine updated (`rea update`, then regenerate the
  catalog)?

---

## Facilitation notes

- **Never demo on live malware in a workshop.** Use the toy binary; it teaches
  the same mechanics without the risk.
- **The ambiguity exercise matters more than the tooling.** Tools are learnable
  in a week; the discipline of not overclaiming is not.
- **Keep the toolkit's honest-limits page on the projector** during Day 2's
  capstone.
- If a machine has no Ghidra, pair that participant with someone who does for
  the engine labs rather than making them sit out.

## Post-workshop

| When | Action |
| --- | --- |
| +1 week | Collect the capstone reports; pick the best two as internal examples |
| +2 weeks | Promote the three most-used participant profiles into `profiles/` |
| +1 month | Re-run the workshop's Lab 3 with the updated toolkit; compare reports |
| +3 months | Audit whether the reports produced since cite evidence — that is the real measure of success |
