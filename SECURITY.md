# Security policy

pcx is a local Windows tuning skill: PowerShell text files, no binaries, no
network calls, no auto-update, no installer. `SAFETY.md` is the threat model and
the design contract; this file says how to report a break in it.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes |
| Older | No |

Only the latest release on `main` receives fixes.

## Report a vulnerability

Use GitHub private vulnerability reporting:
<https://github.com/nzeronfourme/pcx/security/advisories/new>

Do not open a public issue for a security problem, and do not paste secrets,
machine names, user names or full registry exports into a report. Redact them.

Include:

- the commit id or release version;
- the Windows build (`winver`), the PowerShell version, and the harness;
- the exact command or probe spec that triggers the problem;
- what you expected and what happened instead;
- the smallest reproduction you can produce, preferably with the fixture
  adapter under `tests/`;
- redacted `pcx doctor` output.

## In scope

- A write outside the allowed roots, or any write to the boot chain, a security
  service, a kernel driver, an anticheat, a managed device, S Mode or a Dev
  Drive.
- A policy bypass: a target the policy layer refuses being written through a
  different provider, a different spelling, or a plan proposal.
- Snapshot or undo integrity: exit 0 without SHA-256 equality, an undo that
  leaves the target changed, a snapshot that misses a value-level change.
- Spec parsing: command injection, quoting or path traversal through `reg:`,
  `svc:`, `task:`, `file:`, `counter:`, `event:`, `intent:` or `environment:`.
- Elevation: a UAC prompt or a real write without an explicit `tune --apply` or
  `undo`, or any write while `PCX_TEST_RUN=1`.
- Fixture escape: the real platform adapter active during a test run, or a
  test that writes to the live OS.
- Leakage: a private path, user name or workspace name in a shipped file or in
  the `INSTALL.md` manifest.
- A shipped claim that promises exact undo for everything, auto-update, or a
  security property the code does not implement.

## Out of scope

- Bugs in Windows, drivers or third-party applications.
- Changes the table deliberately labels Manual or Don't touch.
- Missing features, FPS or latency requests, and unsupported Windows builds.
- An attacker who already has administrator rights and can replace the scripts
  before they run; pcx is unsigned text and does not defend its own files.
- Social engineering and denial-of-service against GitHub.

## What to expect

This is a single-maintainer project. Reports are handled on a best-effort basis;
there is no SLA and no bug bounty. A confirmed issue is fixed in the next
release and credited in the release notes unless you ask otherwise.

## Safe harbor

Good-faith research on systems you own or are authorised to test is welcome. Do
not run destructive tests against a live OS: use the fixture suite
(`tests/run.ps1`) and the test adapter. Do not touch other people's data, and do
not use a finding to cause harm.
