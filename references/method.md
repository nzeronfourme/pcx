# How to investigate a PC with pcx

This reference is for the agent. The goal is one honest picture of the machine,
built from machine-read values, so the user can choose from the tune table
without guessing.

## The loop

1. `pcx tune` produces the one proposal table. It is read-only and needs no
   administrator.
2. Read the rows and the metrics behind them. A row exists only because a
   measurable value exists.
3. If a question is still open, read further with the read-only surface.
4. Propose a typed target only with evidence that matches the target domain.
5. Apply one item at a time, after the user names it.

## tune

`pcx tune` collects eight read-only groups: identity and build, storage,
services and startup, security state, user intent, printers, memory, and
performance state (HAGS, GPU, GameDVR, power plan, overlay processes, background
load). Every metric carries `measured`, `unavailable` or `unreliable`. A metric
that could not be measured is never a zero.

Use the table, not a summary of the table. The numbers are stable and match the
JSON findings.

## probe

Probes are the free-investigation surface, and they never write:

- `reg:` one registry value,
- `svc:` one service start value,
- `task:` one scheduled task state,
- `file:` path, size, attributes and SHA-256,
- `counter:` a performance counter,
- `event:` a filtered event query,
- `intent:` positive usage history,
- `environment:` build, edition, S Mode, managed state, security state.

Every probe returns one typed result. An unavailable counter or a missing value
stays unavailable. Do not turn it into a number.

## Event logs

Event logs explain what happened, not what should change. Always use a filtered
query with a bounded window. An unfiltered query is refused because it is slow
and proves nothing.

Useful families:

- application crashes and hangs,
- service control manager start and stop failures,
- storage and disk errors,
- driver load and timeout events,
- Windows Update and setup events.

For the table, an event count can be telemetry evidence. The event text itself
is context for the user, never the proof of a benefit.

## WHEA

WHEA events report hardware errors: corrected and uncorrected machine checks,
PCIe errors, memory errors, thermal events. Treat them as diagnostics, not as a
tuning target. Report them plainly:

- which component,
- how many events,
- whether the machine reboots or stops.

Never suggest a registry or service change to hide a WHEA event. Hardware and
firmware fixes stay with the user and the vendor.

## Processes

Read the process list for background load and overlays. Record counts and a few
names, not a private profile of the user. A process is not a target: pcx never
kills a process and never changes another program's settings.

## Services

A service matters in two ways:

1. Its start type is a possible behavior change, and only toward Manual or
   Disabled.
2. Its blast radius decides whether a change is honest: dependents, a listening
   port, or child processes mean the change is refused or demoted to manual.

Security services and kernel drivers are never touched. A service action is
offered only from the catalog and only with evidence.

## Bugs and crashes

When the user reports a bug or a crash:

1. Identify the failing process and the event or WER record.
2. Check for a dirty shutdown, a storage error and a recent driver event.
3. Check memory pressure, free space and power state.
4. Report findings. Do not apply a fix that changes a protected target.

Bug fixing is `manual` unless the catalog offers a specific, reversible action
with matching evidence.

## Evidence rules

- Telemetry evidence is a numeric measurement with a window.
- State evidence is a machine-read value plus a profile.
- An agent-discovered registry, service or task target must cite telemetry in
  the target's own domain. An unrelated metric refuses.
- A state-only performance item is catalog-only.
- A file target must tie its evidence to the same root.

## Engine limits and agent freedom

`pcx` is the fast path for typed changes (registry, service, task, file) with
a value-level snapshot and an evidence-domain check; it is not a gate. The
engine only writes what it can type and snapshot; everything else stays a
conversation. The agent is free to investigate and free to act: it must
propose and fix an out-of-catalog target itself, in the open, with the same
honesty rules (measured evidence, reversible where possible, stated plainly
where not).

## What is never automated

pcx never automates anything that can prevent boot or break security:

- the boot chain and boot drivers,
- security services, Defender configuration and firewalls,
- kernel drivers and device configuration,
- anticheat services, files and tasks,
- managed devices and S Mode,
- Dev Drive volumes,
- ACL and TrustedInstaller ownership,
- Windows.old, WER reports and `%TEMP%`,
- VBS and HVCI,
- arbitrary shell commands and any external binary.

Those items are reported as manual or don't-touch. That is a product rule, not a
temporary restriction.
