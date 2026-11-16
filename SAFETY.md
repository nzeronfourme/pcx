# Safety model

pcx changes a real machine, so the safety claims are part of the product. This
page states what is protected, what is not, and how each claim is proven.

## Threat model

What we defend against:

- **An agent that improvises a write.** The agent is free to investigate and
  free to act; pcx is the snapshot-backed fast path plus the policy gate, not
  the only API. A typed change through pcx must parse as a typed target, sit
  inside an allowed root, carry matching evidence and pass the policy gate.
- **A target outside the catalog.** The agent may propose one and must fix it
  itself when pcx cannot express it; through pcx it is treated exactly like a
  seed action once it passes the same checks, inside allowed roots, with
  telemetry in the target's own domain, and never for a state-only performance
  item.
- **A prompt that asks for a protected change.** The policy gate, not the model,
  decides. Boot chain, security, drivers, anticheats, managed, S Mode and Dev
  Drive are refused in the only writer.
- **A wrong or drifted machine state.** Every write reads the live pre-state,
  records a value-level snapshot, writes, reads back, and refuses on drift.
- **A false rollback claim.** Undo compares the current state to the recorded
  post-state and exits 3 without reverting on any mismatch. There is no force.
- **A tampered journal.** Undo re-runs the policy and plan checks on every
  recorded item before restoring anything.
- **A malicious folder copied from the internet.** `INSTALL.md` pins every
  shipped file by SHA-256; install and verify, or do not run it.
- **A cheap elevation.** One plan, one UAC, canonical bytes and a caller SID.

What is out of scope: a compromised administrator account, a malicious kernel
driver, firmware attacks, and any tool the user runs outside pcx.

## Fixture-only rule

No test writes to the live OS. This is enforced, not promised:

- `PcxPlatform` is the only OS boundary. The test suite swaps it for
  `tests/TestAdapter/PcxPlatform.Test.ps1`, which reads and writes one JSON
  state file.
- `tests/run.ps1` sets a sticky `PCX_TEST_RUN=1` and the test adapter, then
  fails the run if a test cleared the sentinel.
- The real adapter refuses every write while `PCX_TEST_RUN` is set, while the
  arming capability was not set by `pcx.ps1`, or while `PCX_ALLOW_REAL_WRITES`
  is not exactly `1`.
- The repository carries the committed marker `tests/.pcx-test-root`. The real
  adapter walks up from its own location and refuses every write when the marker
  is present, so a test checkout can never write to the real operating system,
  even if a scratch test clears both environment checks.

The marker is the last line of defence. Do not delete it, and do not copy the
product tree into a checkout without it.

## A1 is irreversible

Category A1 deletes OS-regenerable caches: the thumbnail cache, the icon cache,
the Delivery Optimization cache and the Windows Update download cache. A1 has a
manifest-only inverse:

- pcx writes a manifest with path, size and SHA-256 for everything it deleted;
- verify re-reads those paths and requires all of them to be absent;
- residue marks the item FAILED and lists what was already deleted;
- undo reports A1 as not restorable and excludes it from the equality set.

No A1 item is ever described as restorable, and no A1 target may live outside
`a1_roots`.

## Performance: no promise

pcx does not promise frames per second, frame time or latency. Performance rows
report measured state (HAGS, Game DVR, overlays, background load, power plan) and
always say **effect not promised**. A percentage that this machine did not
measure does not appear in the table, in the catalog, or in a summary.

## One UAC

A plan with administrator items runs as one console operation with one UAC
prompt. The parent passes the canonical plan bytes and their SHA-256, never a
writable path. The elevated child recomputes the hash, re-runs the plan
validator, compares the caller SID, and owns the stop loop and the writes. A
declined prompt applies nothing. Undo uses the same mechanism.

## Windows Server limits

pcx targets Windows 10 2004+ and Windows 11. Auto-apply is verified on builds
26100 and 26200; other supported client builds keep every action selectable with
the caveat "not verified on build <n>; effect not promised".

On Windows Server, Server Core, or any unsupported build (pre-19041):

- the build gate demotes every action to Manual;
- metrics that depend on client components report `unavailable`;
- S Mode and managed checks still refuse writes;
- nothing is applied; the demotion reason stays in the JSON groups and the agent
  says it in one line.

Server tuning is out of scope for v0. Do not force an action onto a server.

## The control set rule

A service snapshot records `Start` and the resolved `ControlSet00N`. Undo
refuses when the service now maps to a different control set, because the
recorded value would no longer describe the same location. Service undo restores
`Start` only; it never starts or stops the service. A control-set flip is a
terminal refusal, not a warning.

## Reporting a problem

A safety claim that fails is a blocker. Report the command, the exact output and
the code that was expected, for example `PCX-E-PLATFORM-TESTROOT` or
`PCX-POLICY-BOOTCHAIN`. Do not patch around it.
