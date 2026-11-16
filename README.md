# pcx

The agent investigates the whole PC and fixes it, from one command.

**English** · [Русский](README.ru.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1_%7C_7-blue?style=flat-square)](INSTALL.md)
[![Windows 10 | 11](https://img.shields.io/badge/Windows-10_%7C_11-blue?style=flat-square)](INSTALL.md)
[![Pester 613](https://img.shields.io/badge/Pester-613_passing-brightgreen?style=flat-square)](tests/run.ps1)
[![auto-update never](https://img.shields.io/badge/auto--update-never-red?style=flat-square)](SAFETY.md)

<!-- i18n: ## English lives in this file; ## Русский lives in README.ru.md. -->

You install the skill, type one command (`/pcx`), and the rest happens in chat.
The agent scans the whole machine, shows one table (the pcx report plus its own
extra findings), proposes, asks one short question, and then does the work you pick.

## How it works

1. One command starts everything: you type `/pcx`, or say "optimize this PC",
   and never type another pcx command afterwards.
2. The command runs the scan itself; the agent starts with a compact machine
   summary (OS, hardware, disks — every line with a number), then
   shows one table: number, risk, the exact action with its target, and the
   measured size or machine state. A row appears only when its target exists on
   this machine; the agent adds its own findings to the same table, continuing
   the numbering.
3. In the same message the agent asks one short question with numbers only.
   Nothing is applied before you answer.
4. You pick. The agent does the work, one change at a time, and finishes with
   one report: what changed and how to reverse it, what stayed pending and why.

The agent is free to investigate and free to act. `pcx` is the fast path for
typed changes (registry, service, task, file) because it snapshots; it is not
a gate. If pcx cannot express a change or refuses it, the agent explains why in
one line and does it the right way itself. Two limits are never crossed: never
hide a finding, a refusal or a failure; never touch the boot chain, security
services, kernel drivers, anticheats, managed devices, S Mode or Dev Drive.

## 30-second start

The fastest path is the agent install: paste this repository link into your AI
coding agent and say "install". The agent reads `SKILL.md`, follows `INSTALL.md`,
runs `pcx doctor`, and stops.

Other ways to get the files:

1. **Git clone.**
   ```
   git clone https://github.com/nzeronfourme/pcx pcx
   pwsh -File .\pcx\pcx.ps1 doctor
   ```
   The public link is filled at release; until then `nzeronfourme/pcx` is the
   reserved name used consistently across these docs.
2. **ZIP download.** Download the repository ZIP from its page, extract it,
   then run `pwsh -File <extracted path>\pcx.ps1 doctor`.
3. **Copy an existing checkout.** Copy the pinned folder from a machine that
   already has it, keep the same file list, then run
   `pwsh -File <path>\pcx.ps1 doctor`.

Where the skill folder goes (the directory name must equal the skill name
`pcx`):

| Harness | Skill folder (global) | Skill folder (project scope) |
|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\skills\pcx\` | `.opencode/skills/pcx/` |
| Claude Code | `%USERPROFILE%\.claude\skills\pcx\` | `.claude/skills/pcx/` |
| Codex, Cursor, VS Code | `%USERPROFILE%\.agents\skills\pcx\` | `.agents/skills/pcx/` |

The `/pcx` chat command ships as `command\pcx.md` in the repo. For OpenCode copy
it to `%USERPROFILE%\.config\opencode\command\pcx.md`, and copy `agent\pcx.md` to
`%USERPROFILE%\.config\opencode\agent\pcx.md`: the command runs under that agent,
which denies the task tool so the work cannot be delegated to a subagent.

`INSTALL.md` lists every shipped file with its SHA-256 so a copy can be
verified. On Windows PowerShell 5.1 use
`powershell -NoProfile -ExecutionPolicy Bypass -File <path>\pcx.ps1 doctor`.
`doctor` is read-only: it reports the environment and stops, it tunes nothing.

What the report looks like (real output, rows trimmed):

```
## What I propose

| # | Category | What is proposed | What you get |
|---|---|---|---|
| 1 | 🟢 Safe | Delete the Windows.old folder (C:\Windows.old) | Frees 6.37 GB. The folder is deleted for good; not reversible. |
| 2 | 🟢 Safe | Clear temporary files (%TEMP%) | Frees 1.0 GB. Files held open are skipped; not reversible. |
| 3 | 🟠 Changes behavior | Turn hibernation off (hiberfil.sys) | Frees 12.7 GB. Hibernation and fast startup stop working; restore with powercfg /h on. |
| 4 | 🟠 Changes behavior | Enable HAGS (HwSchMode) | HAGS becomes enabled; DLSS Frame Generation starts working. Effect not promised. The previous value is snapshotted. |
| 5 | 🟠 Changes behavior | Quarantine the startup shortcut (OneDrive.lnk) | OneDrive stops starting at sign-in. The shortcut is quarantined byte for byte and restorable. |
```

Rows appear only for targets that exist on this machine and have a measured
size or state; a missing folder or an empty cache is not a row. The agent adds
its own findings to the same table, continuing the numbering, and the last line
is one question with numbers only.

The category is the risk: 🟢 safe loses no function, 🟠 changes behavior stops a specific function
and is snapshot-reversible, 🔴 risky can affect stability, updates or security. Things that
should never change are not listed in the table at all.

## What it checks

- 13 sections, one file per section under `src/pcx/Diagnostics/`: platform,
  power, storage, memory, background, services, gaming, display, network,
  maintenance, drivers, security, thermal. 13 sections emit exactly the 45
  fixed finding ids. Every section runs to completion under a 120 s guard.
- 8 probe families, one target per `pcx probe` call:
  `reg:<key path>#<value name>`, `svc:<name>`, `task:<full path>`,
  `file:<absolute path>`, `counter:<PDH path>`,
  `event:<log>[;Provider=;Id=;Hours=]`, `intent:<u4|userassist|prefetch|taskhistory>`,
  `environment:`. Every result also names its source, for example
  `platform:registry`. Registry paths always
  carry the drive colon, for example
  `reg:HKCU:\SOFTWARE\Microsoft\GameBar#AutoGameModeEnabled`.
- Its own free investigation. The pcx table cannot carry everything, so the
  agent also looks at the machine itself: processes, startup, tasks, storage,
  network, updates, drivers, power, events, security. A cause named without a
  row from this checklist is a guess, not a finding.

The scan is read-only and needs no administrator. Every metric the engine
cannot measure says `unavailable` or `unreliable` instead of a guessed zero.

## What it can change

13 typed actions (4 Safe + 2 Performance + 7 Behavior), from
`config/actions/*.json` (the JSON files are the source of truth; see
`references/catalog.md`). Builds: auto-apply is verified only on 26100 and
26200. Other supported client builds (Windows 10 19041+ and Windows 11 22000+)
keep every action selectable with the caveat "not verified on build <n>; effect
not promised"; unsupported builds (Server, Server Core, pre-19041) demote every
action to Manual and nothing is applied.

- Safe (A1, manifest-only, not restorable): `thumbnails`, `icon-cache`,
  `delivery-optimization-cache`, `windows-update-download-cache`.
- Performance & latency (snapshot, effect not promised): `game-dvr`, `hags`.
- Changes behavior (snapshot): `diagtrack-u4`, `startup-task-u4`,
  `startup-shortcut-u4`, `spooler-no-printers`, `tips`, `advertising-id`,
  `search-web`.

8 display-only notes (4 Manual + 4 Don't touch), from
`config/actions/manual.json`; pcx measures their targets and never performs them:

- Manual: `windows-old`, `wer`, `temp`, `hiberfil`.
- Don't touch: `vbs`, `anticheat`, `vbs-hvci`, `defender-exclusions`.

`pcx` is the fast path, not a gate: typed changes go through it because it
snapshots and can undo. What pcx never touches: the boot chain, security
services, kernel drivers, anticheats, managed devices, S Mode and Dev Drive.
Those rows stay a conversation, and protected targets stay refused.

## Undo: what is exact and what is not

Undo is best effort, not a promise:

- Typed actions applied through pcx undo exactly: `pcx undo --item <id>`,
  `pcx undo --plan <id>` and `pcx undo --last` restore the value-level
  snapshot and exit 0 only on SHA-256 equality. Exit 3 means undo was
  refused and nothing was reverted: the target drifted, or a policy, journal
  or UAC check failed. There is no force.
- Safe cache deletions are not restorable. pcx writes a manifest (path, size
  and SHA-256 of everything deleted) and reports the rows as not restorable.
- Anything the agent changed outside pcx has no automatic undo. The agent must
  be able to say how to reverse it, and if it cannot be reversed, it says so
  before doing it.

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 (build 19041+) or Windows 11 (build 22000+). Catalog auto-apply is verified only on builds 26100 and 26200. On other supported client builds every action stays selectable with the caveat "not verified on build <n>; effect not promised". On unsupported builds (Server, Server Core, pre-19041) every action demotes to Manual and no row is auto-applicable. |
| Shell | PowerShell 5.1 or PowerShell 7. |
| Tests only | Pester 5 or newer, only to run the test suite. |

## Known limits

- Locked cache files are skipped and listed per file. Safe cache actions skip
  files Windows has open and report them per file instead of failing the
  whole action.
- On builds other than 26100/26200 the caveat "not verified on build <n>;
  effect not promised" is added. On unsupported builds (Server, Server Core,
  pre-19041) every action demotes to Manual and no row is auto-applicable.
- No category C automation. Those findings stay manual, and protected targets
  stay refused.
- No FPS or latency promise. Performance rows report measured state and say
  **effect not promised**; a percentage this machine did not measure never
  appears in the table.
- A scan writes nothing unless `--out` is supplied. Only `tune --apply` and
  `undo` arm real writes, and never while `PCX_TEST_RUN` is set.
- No auto-update, no binaries, no PATH shim. The repository never installs
  itself and never downloads anything at runtime; installation is always your
  explicit action.

## Docs

- `SKILL.md` the agent runbook: scan, probe, apply, undo.
- `command/pcx.md` the `/pcx` chat command: one command, then work in chat.
- `SAFETY.md` the threat model and the fixture-only rule
  ([Русский](SAFETY.ru.md)).
- `INSTALL.md` the pinned manifest ([Русский](INSTALL.ru.md)).
- `references/method.md` how to investigate.
- `references/catalog.md` the 13 applyable actions and the 8 notes.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1`
  and `pwsh -NoProfile -File tests/run.ps1`.

## License

MIT, see `LICENSE`.
