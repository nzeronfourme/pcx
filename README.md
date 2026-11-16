# pcx

**Windows 10/11 optimizer for AI coding agents.**

**English** · [Русский](README.ru.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1_%7C_7-blue?style=flat-square)](INSTALL.md)
[![Windows 10 | 11](https://img.shields.io/badge/Windows-10_%7C_11-blue?style=flat-square)](INSTALL.md)
[![Pester 613](https://img.shields.io/badge/Pester-613_passing-brightgreen?style=flat-square)](tests/run.ps1)
[![auto-update never](https://img.shields.io/badge/auto--update-never-red?style=flat-square)](SAFETY.md)

<!-- i18n: ## English lives in this file; ## Русский lives in README.ru.md. -->

## What it is

pcx is a skill for OpenCode, Claude Code, Codex, Cursor and VS Code. It scans a
Windows 10/11 PC read-only, shows one table of measured proposals, and applies
only the rows you pick. The agent never hides a finding, a refusal or a failure.

## What it does

- Scans 13 areas of the PC read-only and prints one compact machine summary.
- Shows one proposal table: exact target, risk, and measured size or state.
- Applies only the rows you pick, one change at a time.
- Reports what changed and how to reverse it.

## Why pcx

- Every row is measured; a missing target or an unreadable value is not turned
  into a guessed zero.
- Typed changes are snapshotted; safe cache deletions say they are not restorable.
- The boot chain, security services, kernel drivers, anticheats, managed devices,
  S Mode and Dev Drive are never touched.

## How it works

1. Type `/pcx` (or say "optimize this PC"). The command runs the scan itself; you
   never type another pcx command.
2. The agent prints a compact machine summary, then one table: number, risk, exact
   action, target, and measured size or state. A row appears only when its target
   exists on this machine.
3. The agent asks one short question with numbers only. Nothing is applied before
   you answer.
4. You pick. The agent applies the rows one at a time and finishes with one report:
   what changed and how to reverse it, what stayed pending and why.

## Install

Paste this repository link into your AI agent and say "install". It reads
`SKILL.md`, follows `INSTALL.md`, runs `pcx doctor`, and stops.

Or clone:

```text
git clone https://github.com/nzeronfourme/pcx pcx
pwsh -File .\pcx\pcx.ps1 doctor
```

Where the skill folder goes (the directory name must be `pcx`):

| Harness | Global | Project |
|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\skills\pcx\` | `.opencode/skills/pcx/` |
| Claude Code | `%USERPROFILE%\.claude\skills\pcx\` | `.claude/skills/pcx/` |
| Codex, Cursor, VS Code | `%USERPROFILE%\.agents\skills\pcx\` | `.agents/skills/pcx/` |

For OpenCode, copy `command/pcx.md` to
`%USERPROFILE%\.config\opencode\command\pcx.md` and `agent/pcx.md` to
`%USERPROFILE%\.config\opencode\agent\pcx.md`. The command runs under that agent,
which denies the task tool. `INSTALL.md` pins every shipped file with SHA-256;
`doctor` is read-only. On Windows PowerShell 5.1 use
`powershell -NoProfile -ExecutionPolicy Bypass -File <path>\pcx.ps1 doctor`.

## The report

Real output, rows trimmed:

```text
## What I propose

| # | Category | What is proposed | What you get |
|---|---|---|---|
| 1 | 🟢 Safe | Delete Windows.old | Frees 6.37 GB. Not reversible. |
| 2 | 🟠 Changes behavior | Turn hibernation off | Frees 12.7 GB. Restore with powercfg /h on. |
| 3 | 🟠 Changes behavior | Quarantine OneDrive.lnk | OneDrive stops starting. The shortcut is restorable. |
```

Rows appear only for targets that exist with a measured size or state. The agent
adds its own findings to the same table, continuing the numbering, and asks one
question with numbers only. 🟢 loses no function; 🟠 stops a specific function and
is snapshot-reversible; 🔴 can affect stability, updates or security.

## What it checks

13 diagnostic sections emit 45 fixed finding ids. `pcx probe` answers 8 families:
`reg:`, `svc:`, `task:`, `file:`, `counter:`, `event:`, `intent:`, `environment:`.
The agent also investigates the machine itself: processes, startup, tasks,
storage, network, updates, drivers, power, events, security. The scan is read-only
and needs no administrator.

## What it can change

13 typed actions: 4 safe cache deletions (`thumbnails`, `icon-cache`,
`delivery-optimization-cache`, `windows-update-download-cache`), 2 performance
snapshots (`game-dvr`, `hags`), 7 behavior snapshots (`diagtrack-u4`,
`startup-task-u4`, `startup-shortcut-u4`, `spooler-no-printers`, `tips`,
`advertising-id`, `search-web`). The JSON catalog in `config/actions/` is the
source of truth; see `references/catalog.md`.

8 display-only notes are measured but never performed: Manual `windows-old`,
`wer`, `temp`, `hiberfil`; Don't touch `vbs`, `anticheat`, `vbs-hvci`,
`defender-exclusions`.

Builds: auto-apply is verified only on 26100/26200. Other supported client builds
keep every action selectable with the caveat "not verified on build <n>; effect
not promised"; unsupported builds (Server, Server Core, pre-19041) demote every
action to Manual.

## Undo

- Typed actions undo exactly: `pcx undo --item <id>`, `--plan <id>` or `--last`
  restore the snapshot and exit 0 only on SHA-256 equality. Exit 3 means refused
  and nothing was reverted.
- Safe cache deletions are not restorable; pcx writes a manifest with path, size
  and SHA-256 of everything deleted.
- Anything changed outside pcx has no automatic undo; the agent says how to
  reverse it, or says it cannot, before doing it.

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 19041+ or Windows 11 22000+. |
| Shell | PowerShell 5.1 or 7. |
| Tests only | Pester 5 or newer. |

## Known limits

- Locked cache files are skipped and listed per file.
- No FPS or latency promise. Performance rows say **effect not promised**; a
  percentage this machine did not measure never appears.
- A scan writes nothing unless `--out` is supplied. Only `tune --apply` and `undo`
  arm real writes, and never while `PCX_TEST_RUN` is set.
- No auto-update, no binaries, no PATH shim. Installation is always your action.
- No category C automation; those findings stay manual, and protected targets
  stay refused.

## Docs

`SKILL.md` (runbook) · `INSTALL.md` ([RU](INSTALL.ru.md)) · `SAFETY.md` ([RU](SAFETY.ru.md)) · `command/pcx.md` · `references/method.md` · `references/catalog.md`.

Tests: `pwsh -NoProfile -File tests/run.ps1`.

## License

MIT, see `LICENSE`.
