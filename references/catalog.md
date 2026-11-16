# Seed action catalog

This reference mirrors `config/actions/*.json`. The JSON files are the source of
truth; if this page and the JSON disagree, the JSON wins and this page is stale.

Every action is verified on builds `26100` and `26200`. Other supported client
builds keep the action selectable with the caveat "not verified on build <n>;
effect not promised"; unsupported builds (Server, Server Core, pre-19041) demote
it to Manual and never apply it.

Categories: `A1` deletes an OS-regenerable cache and is **not restorable**.
`B` is a behavior or performance change with a value-level snapshot, except the
Startup shortcut, which is quarantined byte for byte.

## Safe: 4 actions

| id | target | category | inverse | evidence |
|---|---|---|---|---|
| `thumbnails` | 4 `thumbcache_*.db` files under `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | A1 | manifest-only | telemetry `storage.system_free_bytes`, domain storage |
| `icon-cache` | 7 `iconcache_*.db` and `iconcache_idx.db` files under the same Explorer folder | A1 | manifest-only | telemetry `storage.system_free_bytes`, domain storage |
| `delivery-optimization-cache` | the Delivery Optimization cache directory | A1 | manifest-only | telemetry `storage.system_free_bytes`, domain storage |
| `windows-update-download-cache` | `%SYSTEMROOT%\SoftwareDistribution\Download` | A1 | manifest-only | telemetry `storage.system_free_bytes`, domain storage |

Windows regenerates every Safe target. pcx writes a manifest and never promises
a restore.

## Performance and latency: 2 actions

| id | target | category | inverse | evidence |
|---|---|---|---|---|
| `game-dvr` | `GameDVR\AppCaptureEnabled` and `System\GameConfigStore\GameDVR_Enabled` | B | snapshot | state `performance.game_dvr_enabled`, domain performance, `equals:true` |
| `hags` | `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` value `HwSchMode` | B | snapshot | state `performance.hags_mode`, domain performance, `is-off` |

Both are state only: they report a measured setting and **effect not promised**.
`hags` is offered only when HAGS currently reads off. DLSS Frame Generation needs
HAGS, so turning it off can break that feature.

## Changes behavior: 7 actions

| id | target | category | inverse | evidence |
|---|---|---|---|---|
| `diagtrack-u4` | service `DiagTrack`, Start 4 | B | snapshot | telemetry `intent.prefetch_files`, domain intent, `at-least:1` |
| `startup-task-u4` | scheduled task `\Startup\Example App`, Enabled false | B | snapshot | telemetry `intent.task_history_events`, domain intent, `at-least:1` |
| `startup-shortcut-u4` | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk`, quarantined | B | quarantine | telemetry `intent.userassist_entries`, domain intent, `at-least:1` |
| `spooler-no-printers` | service `Spooler`, Start 4 | B | snapshot | state `printers.count`, domain printers, `equals:0` |
| `tips` | `ContentDeliveryManager` value `SubscribedContent-338389Enabled` | B | snapshot | state `ux.tips_enabled`, domain ux, `equals:true` |
| `advertising-id` | `AdvertisingInfo` value `Enabled` | B | snapshot | state `ads.advertising_id_enabled`, domain ads, `equals:true` |
| `search-web` | `Search` value `BingSearchEnabled` | B | snapshot | state `search.web_results_enabled`, domain search, `equals:true` |

The three `-u4` actions are offered only with positive usage evidence. The
Startup shortcut is preserved byte for byte and is the only file action that is
restorable. Service actions change only the Start value, never stop the service,
and are refused when a dependent, a listening port or a child process exists.

## Manual: 4 entries, measured and performed by the agent

These carry no write target and no inverse. Each names a concrete file target in
`measure`; the table prints the row only when that target exists and is not
empty, and always states the measured size. pcx never performs them; the agent
does the delete or the `powercfg` call when the user picks the row.

| id | what it is | measure target | risk |
|---|---|---|---|
| `windows-old` | the previous Windows installation folder | `%SYSTEMROOT%\..\Windows.old` | safe |
| `wer` | Windows Error Reporting files | `%PROGRAMDATA%\Microsoft\Windows\WER` and `%LOCALAPPDATA%\Microsoft\Windows\WER` | safe |
| `temp` | `%TEMP%` | `%LOCALAPPDATA%\Temp` | safe |
| `hiberfil` | the hibernation file | `%SYSTEMROOT%\..\hiberfil.sys` | behavior |

An absent or empty target is not a row. A directory size is the real walk size;
a truncated walk is printed as a lower bound, and an unreadable target states
that its size needs administrator rights.

## Don't touch: 4 entries

| id | what it is | why not |
|---|---|---|
| `vbs` | Virtualization-Based Security | disabling it weakens protection and breaks compatibility |
| `anticheat` | anticheat services, files and tasks | changing them can block a protected game |
| `vbs-hvci` | VBS and HVCI memory integrity | disabling them weakens protection for a gaming trade |
| `defender-exclusions` | Defender exclusion settings | excluding paths weakens protection |

## Protected targets

The catalog is knowledge, not the boundary. `config/protected/protected-targets.json`
holds the deny lists: boot chain, security keys and services, kernel drivers,
TrustedInstaller keys, anticheat, system tasks under `\Microsoft\Windows\`, and
the entire `HKCU` surface outside the enumerated subtrees. A target on a deny
list is refused even if some action were to name it.
