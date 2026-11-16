# Contributing

pcx is a small, deliberately narrow tool: one command, one proposal table,
typed writes with a snapshot, and an honest undo boundary. Changes that widen
that scope are likely to be declined; changes that make the existing contract
more exact are welcome.

## Ground rules

1. **Fixture-only tests.** No test writes to the live OS. `PcxPlatform` is the
   only OS boundary, and tests swap it for
   `tests/TestAdapter/PcxPlatform.Test.ps1` through `tests/run.ps1`.
2. **Typed writes only.** Registry, service, scheduled task and file targets
   inside the allowed roots, gated by policy, snapshotted before the write, one
   item per call. No boot chain, security services, kernel drivers, anticheats,
   managed devices, S Mode or Dev Drive.
3. **No new runtime dependency, network call, binary, installer, PATH shim or
   auto-update.** The repository never installs itself and never downloads
   anything at runtime.
4. **Windows PowerShell 5.1 compatibility is mandatory.** PowerShell 7 is the
   second host, not the only one. Any `.ps1` with non-ASCII text is written as
   UTF-8 with BOM: PowerShell 5.1 reads a BOM-less file as ANSI and fails to
   parse it.
5. **One logical change per commit.** No binaries and no secrets in history.
6. **Docs stay bilingual.** `README.md`/`README.ru.md`, `SAFETY.md`/
   `SAFETY.ru.md`, `INSTALL.md`/`INSTALL.ru.md` must state the same facts.

## Setup

```powershell
git clone https://github.com/nzeronfourme/pcx pcx
cd pcx
pwsh -NoProfile -File tests/run.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
```

Pester 5.0.0 or newer is required only to run the suite. The runner sets the
sticky `PCX_TEST_RUN=1` sentinel, refuses the real adapter, and fails closed.

## Where things live

| Path | What it is |
|---|---|
| `pcx.ps1` | CLI entry point |
| `src/pcx/Commands/` | one file per command |
| `src/pcx/Core/` | catalog, policy, snapshot, state, text, platform boundary |
| `src/pcx/Diagnostics/` | 13 sections, 45 fixed finding ids |
| `src/pcx/Collectors/` | 8 probe families |
| `src/pcx/Providers/` | registry, service, task, file writes |
| `config/actions/` | the action catalog; the JSON files are the source of truth |
| `tests/Pester/` | unit, property and safety suites |
| `tests/E2E/` | end-to-end replay |
| `references/` | method and catalog documentation |

## Changing an action

- Edit `config/actions/*.json`; do not hard-code an action in the engine.
- Keep the risk level honest: `safe` loses no function, `behavior` stops one
  specific function and is snapshot-reversible, `performance` promises no
  effect. Only builds 26100 and 26200 may be pinned as verified.
- Every applyable action needs a snapshot inverse and a policy-allowed target.
  Manual and Don't-touch entries stay display-only and carry a measure target.
- Update `references/catalog.md` and the counts in the shipped docs if the
  catalog size changes.
- Add or update the test that proves the new shape, and re-pin the manifest.

## Tests and counts

Run the full suite on both hosts before opening a pull request. If the suite
count, the catalog size, the number of display-only notes, the number of
sections or probe families changes, update every shipped document that states
it: `README.md`, `README.ru.md`, `SKILL.md`, `SAFETY.md`, `SAFETY.ru.md`,
`INSTALL.md`, `INSTALL.ru.md`, `references/catalog.md`.

## The pinned manifest

`INSTALL.md` pins every shipped file with its SHA-256. `INSTALL.ru.md` carries
the same table except its own row. After changing any shipped file, re-pin both
files with the new byte hashes; the Safety suite fails if a hash is stale.

Not every public file is a shipped file. `INSTALL.md`, `SECURITY.md`,
`CONTRIBUTING.md` and `.github/` are part of the public repository but are not
part of the skill package, so they are not listed in the manifest. They are
still included in the release export.

## Commit messages

- `feat(core|providers|collectors|cli|skill): <summary>`
- `chore(repo): <summary>`
- `docs: <summary>`
- `test(e2e): <summary>`

## Pull requests

Fill in `.github/PULL_REQUEST_TEMPLATE.md`, include the test output for both
hosts, and state the risk and the rollback for anything a user can apply. Do not
force-push `main`; do not include generated archives or binaries.
