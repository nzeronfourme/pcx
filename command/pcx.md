---
description: Analyze this PC with pcx and improve it — one command, then work in chat
agent: pcx
subagent: false
---

Load the `pcx` skill and run its whole scenario. The user typed one command; from
here everything happens in this chat.

The live scan runs here, before you answer, and is saved to a JSON file. Read
that file with the shell: it carries `data.table`, `data.metrics`,
`data.diagnostics`, `data.environment` and `data.findings`.

!`$roots = @((Join-Path $HOME '.config\opencode\skills\pcx'), (Join-Path (Get-Location) '.opencode\skills\pcx'), (Join-Path $HOME '.agents\skills\pcx'), (Join-Path $HOME '.claude\skills\pcx')); $root = $roots | Where-Object { Test-Path (Join-Path $_ 'src\pcx\Pcx.psm1') } | Select-Object -First 1; if ($root) { Import-Module (Join-Path $root 'src\pcx\Pcx.psm1') -Force; $out = Join-Path $env:LOCALAPPDATA ('pcx\scans\pcx-command-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'); $run = Invoke-PcxTune -Arguments @('--table', '--out', $out); if ($run.ExitCode -eq 0) { 'PCX_SCAN_FILE=' + $out } else { 'PCX_SCAN_FAILED=' + @($run.Envelope.diagnostics)[0].message } } else { 'PCX_SKILL_NOT_FOUND' }`

If the block printed `PCX_SKILL_NOT_FOUND` or `PCX_SCAN_FAILED`, find the
installed `pcx.ps1` and run `pwsh -File <path> tune --table --out <file>` in this
session. If the table language is not the user's, add `--lang <code>`.

1. Read the file at `PCX_SCAN_FILE` and keep `data.table`, `data.metrics`,
   `data.diagnostics`, `data.environment` and `data.findings`.
2. Print the compact machine summary from SKILL.md "Report shape": 3-4 lines,
   every line with a number — OS build; CPU/GPU/RAM total, free and commit;
   each disk's model, free/total, health, wear and temperature. Nothing else:
   no uptime, power plan, top apps, patch age, process or error counts.
3. Print `data.table` exactly as returned, no code fence, then your own rows
   N+1 in the same table, same four columns and risk scale (safe, changes
   behavior, risky). Copy pcx values verbatim. Do not print a second table, a
   table-revision section, a `skip N` list or a restatement. Every row you add
   names the exact target (shortcut file, folder, game, service, task) and
   states a measured size or machine state, what changes on this PC, and how to
   reverse it. No number or state, no row. No target on this machine, no row.
   A size row below 500 MB is not printed unless removing it fixes a named
   function or security issue, and then the row says why. Account for all 12
   domains: a cache-only table is incomplete; every top cause must have a row
   number. Never propose creating a restore point.
4. At most two short lines: the top causes and what is already good. If the
   table has no rows, or everything is already configured, print one line
   starting `already good:` and stop. Do not invent rows.
5. End with ONE bold question as the last line, numbers only, in the user's
   language: **What do we do: 1, 2, 7?** / **Что делаем: 1, 2, 7?** Never ask
   "manual or admin", never ask per row, never use a question card.

Step 3 after the user answers with numbers:

- pcx catalog rows (`source = catalog`) go through
  `pwsh -File <path>/pcx.ps1 tune --apply <numbers>`, one item at a time.
- manual rows (`source = manual`) you perform yourself: delete Windows.old, WER
  and `%TEMP%`, run `powercfg /h off` for hibernation, verify each, and say how
  it reverses. Do not create a restore point.
- only BIOS/firmware, installing Windows updates, resizing the pagefile and
  physically moving games are handed to the user; that fact belongs in the row,
  not in a second question.
- stop immediately on `s` or «стоп». Never touch the boot chain, security
  services, kernel drivers, anticheats, managed devices, S Mode or Dev Drive.
- finish with one short report: what changed and how to reverse it, what stayed
  pending and why.

Rules for the whole run:

- The scan, the report and the question happen in this session. Never use the
  task tool or a subagent for them: the scan already ran here and the user must
  answer here.
- Write everything to the user in the user's language (Russian when the user
  writes Russian). Only machine evidence stays verbatim.
- Ask by plain chat message. Do not use a question card, an interactive form or
  a multiple-choice widget.

The user answers with plain chat replies ("1 and 4", "go ahead", "всё кроме пятого"); they never run CLI commands or pass flags.

If `pcx` is not installed yet, install it first exactly as `INSTALL.md` describes,
then continue — the user asked for the result, not for a second step.
