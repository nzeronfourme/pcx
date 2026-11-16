## Summary

<!-- One paragraph: what changes and why. -->

## Contract checklist

- [ ] Fixture-only: every test goes through `tests/run.ps1`; nothing writes to
      the live OS.
- [ ] Typed writes only; policy gate, snapshot and one item per call are intact.
- [ ] No new runtime dependency, network call, binary, installer, PATH shim or
      auto-update.
- [ ] Windows PowerShell 5.1 and PowerShell 7 both pass.
- [ ] Any non-ASCII `.ps1` is UTF-8 with BOM.
- [ ] Shipped counts updated in every document that states them (tests,
      actions, notes, sections, probe families).
- [ ] If a shipped file changed, `INSTALL.md` and `INSTALL.ru.md` were
      re-pinned.
- [ ] No secrets, private paths, machine names or binaries in the diff.

## Verification

```text
paste the runner summary for both hosts here
```

## Risk and rollback

<!-- What a user can apply from this change, the risk level, and the inverse.
Write "docs only" when nothing can be applied. -->
