---
name: Bug report
about: A command, a scan, or a table row does something other than documented
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- One paragraph. The exact command is better than a description. -->

## What you expected

<!-- Quote the shipped promise you relied on, with the file name. -->

## Steps to reproduce

1.
2.
3.

## Environment

- pcx version or commit id:
- Windows build (`winver`):
- PowerShell: 5.1 / 7 (and the exact version):
- Harness: OpenCode / Claude Code / Codex / Cursor / VS Code / terminal

## Evidence

<details><summary>pcx doctor output (redacted)</summary>

```
paste here
```

</details>

<details><summary>Scan or table output (redacted)</summary>

```
paste here
```

</details>

## Safety check

- [ ] I removed user names, machine names, private paths and secrets.
- [ ] I did not run `tune --apply` or `undo` to reproduce this.
- [ ] This is not a security report; security reports go through the private
      advisory link in `SECURITY.md`.
