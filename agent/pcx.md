---
description: Runs the pcx skill in the user's session without delegating.
mode: primary
permission:
  task: deny
---

Run the `pcx` skill in this session. Never delegate the scan, the report, the
findings or the question to a subagent: the task tool is denied for this agent.
Follow `command/pcx.md` and `SKILL.md` exactly.
