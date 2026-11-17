# Workshop Invite — draft

Copy this into the calendar invitation and the announcement channel.

---

## Title

**Reverse-Engineering Workshop — From "what is this binary?" to an evidence-backed report**

## When / where

- **Dates:** Day 1 and Day 2 (see `AGENDA.md`)
- **Time:** 09:00–17:00 both days, with a 1-hour lunch
- **Room:** _(fill in after booking)_
- **Remote:** _(video link, same room for hybrid participants)_
- **Capacity:** 8–16

## Who

Engineers who will analyse shipped artifacts — support, platform, security,
release engineering. No prior reverse-engineering experience required; comfort
with a terminal is.

## What you will be able to do afterwards

- Classify any binary, package, or firmware image and know which analysis
  applies to it
- Run the team's toolkit to produce a reproducible, evidence-backed report
- Read decompiled functions and trace a feature through them
- State what a binary does **and** what you could not determine — without
  overclaiming
- Write a reusable profile for your team's most common target type

## Prerequisites (30 minutes, do this before Day 1)

```bash
node --version                 # 20 or newer
npm i -g rea-agents            # the engine
rea setup --client pi --skill --yes
rea doctor --json              # expect skill.state: aligned
git clone <repo> && cd re-toolkit
bash tests/test-toolkit.sh --fast   # expect all pass
```

Install `binutils` (`apt install binutils file` on Linux,
`choco install mingw` on Windows).

**If `rea doctor` does not report an available provider, tell me before Day 1** —
that is the only setup problem that blocks the labs.

## What to bring

- A laptop with admin rights
- Docker Desktop or the ability to run a VM (Day 2 dynamic labs)
- One **safe** binary from your own work you would like to analyse — a build
  you produced, not third-party code you are not authorized to examine

## Pre-reading (20 minutes)

- [Cheat sheet](docs/RE-CheatSheet.md)
- [Limits and honest claims](docs/RE-Cookbook.md#12-limits-and-honest-claims)

Skim; we will use both during the sessions.

## Agenda summary

| Day | Morning | Afternoon |
| --- | --- | --- |
| 1 | Scope and the law · reading a binary without running it · static analysis at depth | The pipeline · writing your own profile |
| 2 | Dynamic analysis (VM only) · evidence discipline · the ambiguity exercise | Platform tracks · capstone: "what would you tell a product owner?" |

Full detail: [`AGENDA.md`](AGENDA.md)

## Ground rules

- **Only analyse what you are authorized to analyse.** Bring your own builds.
- **No live malware.** All labs use a purpose-built toy binary and legitimate
  open-source binaries.
- **Dynamic labs stay in the VM.** Nothing leaves it.
- Everything said in the room about a specific binary stays in the room.

## Capstone

Each team gets one target and one question:

> *"What would you tell a product owner about this binary?"*

One page. Three findings. Each cites an evidence id. One explicit statement of
what remains unknown.

## After the workshop

- Your best profiles get promoted into `profiles/` for the whole team
- The two best capstone reports become internal worked examples
- We re-run one lab a month later and compare reports, to check the toolkit is
  actually improving

## RSVP

Reply with:

1. Which days you can attend
2. Your OS (Linux / macOS / Windows)
3. Whether you have Docker or a VM available
4. One thing you would like to be able to analyse by the end

---

### Facilitator checklist (not for participants)

| # | Task | Owner | Done |
| --- | --- | --- | --- |
| 1 | Book the room for both days | | ☐ |
| 2 | Confirm the video link works from the room | | ☐ |
| 3 | Build the lab VM image with the toolkit pre-installed | | ☐ |
| 4 | Prepare lab targets (see `lab-targets.md`) | | ☐ |
| 5 | Print or host the cheat-sheet PDF | | ☐ |
| 6 | Send pre-reading + prerequisites at T-7 days | | ☐ |
| 7 | Send a reminder at T-1 day | | ☐ |
| 8 | Check every participant passed `rea doctor` before Day 1 | | ☐ |
| 9 | Prepare the ambiguous-report exercise for Lab 6 | | ☐ |
| 10 | Arrange feedback collection for the retro | | ☐ |
