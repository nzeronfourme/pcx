# Install pcx

pcx is a text-only PowerShell skill. Installation is your explicit action:
the repository never installs itself, never updates itself and never adds itself
to PATH.

## Release identity

Release commit id: `fd4a554c493535a9175efb7f13cfa2c99dd96345`

Before a release this file carries the placeholder above; that is the legitimate
pre-release state. When a release is cut, the release process replaces the
placeholder with the 40-hex commit id of the tagged commit and changes nothing
else. This file stays self-contained on purpose: it never embeds its own hash.
Every other shipped file is pinned by SHA-256 in the table below, so a copy is
verifiable whether or not the release field is still a placeholder.

## Requirements

- Windows 10 2004+ (build 19041+) or Windows 11 (build 22000+).
  Auto-apply is verified only on builds 26100 and 26200. Other supported
  builds keep every action selectable with the caveat "not verified on build
  <n>; effect not promised"; unsupported builds (Server, Server Core,
  pre-19041) demote every action to Manual and apply nothing.
- PowerShell 5.1 or PowerShell 7.
- Pester 5 or newer, only to run the test suite.

## Install

### Agent install (the SKILL.md path)

Paste the repository link and say "install". The agent reads `SKILL.md`, installs
the pinned folder exactly as this file describes, runs the doctor command below and
stops.

### Where the skill folder goes

The directory name must equal the skill name (`pcx`): the Agent Skills
specification requires the frontmatter `name` and the parent directory to agree.
Install for the harness the user actually runs:

| Harness | Global (recommended) | Project scope |
|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\skills\pcx\` | `.opencode/skills/pcx/` |
| Claude Code | `%USERPROFILE%\.claude\skills\pcx\` | `.claude/skills/pcx/` |
| Codex, Cursor, VS Code | `%USERPROFILE%\.agents\skills\pcx\` | `.agents/skills/pcx/` |

A working install needs `SKILL.md`, `INSTALL.md`, `references/`, `src/`,
`config/`, `pcx.ps1`, plus `command/pcx.md` and (for OpenCode) `agent/pcx.md`.
The test suite is not required to run the skill; keep it
only if the user wants to run the checks. Do not copy `tests/` into the skill
folder: the committed marker `tests/.pcx-test-root` makes the real adapter
refuse every write, so a copied checkout stays read-only.

### The one-command entry

The skill folder alone is not enough for the `/pcx` flow: the command file has to
be installed where the harness looks for commands.

| Harness | Where `command/pcx.md` goes |
|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\command\pcx.md` (or `.opencode/command/pcx.md` in a project) |
| Claude Code, Codex, Cursor, VS Code | not copied: the skill starts from its own trigger phrases (`optimize this PC`, «оптимизируй ПК») |

The command is OpenCode-specific. It runs under the `pcx` agent, which denies the
task tool: copy `agent/pcx.md` to `%USERPROFILE%\.config\opencode\agent\pcx.md`
(or `.opencode/agent/pcx.md`) as well. Without that file `/pcx` selects an
unknown agent. Other harnesses do not need it; the skill is still fully usable
there from its trigger phrases.

### Manual install

1. Clone the repository or download its ZIP, or copy a folder that already matches
   the table below.
2. Keep the file list exactly as pinned. Do not add binaries and do not drop files.
   Copy `command/pcx.md` to where the harness looks for commands, and on OpenCode
   also copy `agent/pcx.md` to its agent folder (see the tables above).
3. Run the doctor command from the installed path.

```
pwsh -File <path>/pcx.ps1 doctor
```

On Windows PowerShell 5.1:

```
powershell -NoProfile -ExecutionPolicy Bypass -File <path>/pcx.ps1 doctor
```

`doctor` is read-only. It reports the PowerShell version, the OS build, the module
load, the per-user state folder and whether fixture mode is active. Then stop:
installation does not tune anything.

## What installation does not do

- No binaries. Every shipped file is text, and there is no external binary, no C
  tool and no downloaded executable.
- No auto-update. Nothing in the repository updates itself, installs anything or
  changes PATH.
- No background service and no scheduled task.
- No machine-wide state. State lives in `%LOCALAPPDATA%\pcx`.

## Verify the copy

Every shipped file and its SHA-256:

| File | SHA-256 |
|---|---|
| `.gitattributes` | `0b44865e892d68e4468a5f14c7293d5f4c0bed7531e4be3875a07a150b033bfd` |
| `agent/pcx.md` | `4be9a0c84d489628d28b516f6f710d2963148d24d40c9fb4d3edf3e620a4d5df` |
| `command/pcx.md` | `109a5a63ef30ef136b7eb110c8c079a496d351ef390988d20fd66c56467d5b97` |
| `config/actions/behavior.json` | `0af3f68826ea97e80bc575e42d7f39fa929bd02fb24cfbc70fd6f1bb904a626b` |
| `config/actions/cleanup.json` | `fa93fe7ae2d69ddcc3383974c6f8ca0a97ab29c92b0182c4e7abdc8b535ee6db` |
| `config/actions/manual.json` | `77a41117d7e56a45d43bdd0739c26417205e0a703a84b6d41db75e9d64aab446` |
| `config/actions/performance.json` | `6a1e40d3c0856b770588aacd027dcfd65687df356efe6d715c115587b3380bce` |
| `config/evidence-domains.json` | `57d6355965512acd686586c6b850552b520ef0df8eb0885a4c40fabfd365f6b7` |
| `config/protected/protected-targets.json` | `a1b096fba8f20dcc3450f9c9a0d1da85a1f02b05169b7f854fbbc6dc7dccb0b6` |
| `INSTALL.ru.md` | `f263765f8551cf77ed84e80669043371b430e1fc68f8c933b7c47eb0f48541e0` |
| `LICENSE` | `612163dc0982463f13055b86b07a6cc836819692a8f17f9ccf1023e869ae0cac` |
| `pcx.ps1` | `24e70a97363ea2078239e79d517f7304aa2486ffefdf6569fbac101e82194243` |
| `README.md` | `1b8e6f267d9abf8a4db171e30530445545b0e58804be626d2968dd5798d8a799` |
| `README.ru.md` | `fb3ba875f582fadc1b1a805f9c5342ea191cb9261a39a76bf5f84a16982c7126` |
| `references/catalog.md` | `8d9e78bacfaf9e41bacd2f9d4bbb0e5e301b1e749ce8d14fd4ae6629f072f607` |
| `references/method.md` | `a7cc64d937bd4a24d136942fb995d62601094a8ad86ff0f710db26c752a6f7a7` |
| `SAFETY.md` | `b07d5dbfe5eca2fd4a5c362b9dcbbade2c410a7607dcce17626156bd51206bec` |
| `SAFETY.ru.md` | `a6957e5244332e614b90fbdc6b07e1841641e460bb1defe722642d939ef41329` |
| `SKILL.md` | `73628f1843a87058edc69712179ef1299cc246939821ffd8929380ee38616b3a` |
| `src/pcx/Collectors/IdentityCollector.ps1` | `19c07e1649cecb1d41b19bd06ba11f8c57f74a7b9f92f5736f26912434f1fb47` |
| `src/pcx/Collectors/IntentCollector.ps1` | `8a35277827518680651a504a019d129a853a2c9a515f3b56cedc7ff282ac8241` |
| `src/pcx/Collectors/MemoryCollector.ps1` | `8672e00f7b57ec0445bc16d02ec2e68a7e6d511c63d5c09669de585372e26abb` |
| `src/pcx/Collectors/PerformanceCollector.ps1` | `64a485945bc7894123a7c971008b31170d14aa5bd746222f5816e0f4f7110c26` |
| `src/pcx/Collectors/PrintersCollector.ps1` | `52a2242a2f2327d92e2c7f29c42932b26173cb060168b823c003965622df65bf` |
| `src/pcx/Collectors/SecurityStateCollector.ps1` | `fdf566339b95c7e904290f550252df28acee0e867fe89aa3672dbef1d5c9ed0b` |
| `src/pcx/Collectors/ServicesStartupCollector.ps1` | `550a5d5fe06d6532440d61215aacc0752822c0305296d8f5c7be361eb1f8d3ed` |
| `src/pcx/Collectors/StorageCollector.ps1` | `a08ee91157ce2d1475d1395a3d3e4b47705c2a27cfa008577628798cb7fb1934` |
| `src/pcx/Commands/Invoke-PcxApply.ps1` | `d40efd8fb703e52fdd47fbc4948bac0f18125df95fb8e42c627e8b3b4c019552` |
| `src/pcx/Commands/Invoke-PcxDoctor.ps1` | `4193d08a2e553ab176d34c41e44f4cf40a9722e374168ebd8b194721681b0ac5` |
| `src/pcx/Commands/Invoke-PcxPlan.ps1` | `a11167dc2f46cf78ef9e0b3d285f938ae41e36e6ef01e0765bc2c4176ae5f36e` |
| `src/pcx/Commands/Invoke-PcxProbe.ps1` | `3a557538bc69865d2f70f9dae02796521de7cbbbc844fc2bf8b3cafc0eaced19` |
| `src/pcx/Commands/Invoke-PcxQueue.ps1` | `309145a99e640f6e9f726a34f48412591d396b689d68877e57ef0844a8fbf9c1` |
| `src/pcx/Commands/Invoke-PcxStatus.ps1` | `4a3d976976188046d401abd79a31c147f32d5a640ad6df1acffe604be701d699` |
| `src/pcx/Commands/Invoke-PcxTable.ps1` | `32137a300c34fd550be10c0f0cf73932c30e1073746cd4caa319d28dda6a1dea` |
| `src/pcx/Commands/Invoke-PcxTune.ps1` | `dfde432de14bab1e26c436f69b4b2cbedf7cb80e7f63da3977ecd0ee9d71d935` |
| `src/pcx/Commands/Invoke-PcxUndo.ps1` | `2ee775ab818d11797da04c8be7f2a5f0ed969348a950dd374905fe67f096a869` |
| `src/pcx/Core/PcxCatalog.ps1` | `1b6a6fb1f338b10c3626ff1d2032d1fccc052a6553e2e8bfe33e924a8b0b6d31` |
| `src/pcx/Core/PcxEnvelope.ps1` | `d0133ee9a34d9aa1832b98b95e1469944c3e836d755684734bc17364c0735d3a` |
| `src/pcx/Core/PcxEnvironment.ps1` | `6d8bee870393d733d94a3ce099b8f983d9e34db419c30634b0c3960fc3277b6d` |
| `src/pcx/Core/PcxEvidence.ps1` | `58c46794353147d934838de0bcb283af863cd7bed865a499bb4d470ea9e93e34` |
| `src/pcx/Core/PcxFindings.ps1` | `d240a9cef68c106405aea1e481263d479e9da9b5c9b493a496b73846026f9b7e` |
| `src/pcx/Core/PcxJson.ps1` | `761ee151a05b60ed78d0126bef2fc4dfe95615627c4e8b340ea889ad3446e9a1` |
| `src/pcx/Core/PcxPlatform.ps1` | `f233c21d8ecdf9b9e579f958ca108e8e590da3c26087a71218a4bf0a7786402a` |
| `src/pcx/Core/PcxPolicy.ps1` | `6100f98b47df4016b90cb8e7223dafae8b5b90d9688b3fd45f3d4e3853c850e9` |
| `src/pcx/Core/PcxSnapshot.ps1` | `70ceb893a9e3962adf8b0b1a652c753269d9790873fc8d0ee5d68493106f0f78` |
| `src/pcx/Core/PcxState.ps1` | `1cf1645c63aa78a07bb074e670a1304fb76a72f68790b42b5c184ab8bacffd35` |
| `src/pcx/Core/PcxText.ps1` | `833c8e77af37a81e6870c00246fd96b11af19fdd5a72599a61a62f9b33e6a51d` |
| `src/pcx/Diagnostics/BackgroundDiagnostics.ps1` | `89594ee30451ac9760e99ee0f4b8f8a7dd69af5f93ade968e3ce100e01ba22be` |
| `src/pcx/Diagnostics/DisplayDiagnostics.ps1` | `e5ba73eae64d9ed9769ec838abae626218d00a80ef21699416c7c61e6ed7771e` |
| `src/pcx/Diagnostics/DriversDiagnostics.ps1` | `e1941ccd9c1dd66cf7bc9626e05da6211a074aac1b597072ba91a31b5bbaf257` |
| `src/pcx/Diagnostics/GamingDiagnostics.ps1` | `370a4905e078a4613cf507849acfb5f9b94d719d95835c4899c3b410907d2698` |
| `src/pcx/Diagnostics/MaintenanceDiagnostics.ps1` | `cd46d8d274e5a8b606e79f7ef866ca316076f21cd585caad8e1d554555e23d40` |
| `src/pcx/Diagnostics/MemoryDiagnostics.ps1` | `b5c897d709daab3599c39ccd969728a8a07c8ab6dd334d452a0d21008feb61db` |
| `src/pcx/Diagnostics/NetworkDiagnostics.ps1` | `fdd10fa59cbf6b3efb125967d606f6f9d23812e1fc3b7f36cf3fd003b2de1553` |
| `src/pcx/Diagnostics/PlatformDiagnostics.ps1` | `13f485317eecd73fb962479ae40d59472884b13d75124277c8da9761c7b691e8` |
| `src/pcx/Diagnostics/PowerDiagnostics.ps1` | `974b8ed33c76b1a4807cae77e5f26601d33913572aacb8656f91d97841c35018` |
| `src/pcx/Diagnostics/SecurityDiagnostics.ps1` | `ff9c68304bb00a5bce0a4450ef8f380071165afece165a7dd10c2e07cf82d794` |
| `src/pcx/Diagnostics/ServicesDiagnostics.ps1` | `52de620dbf5c533bbe96ee0d7466540bc7e1aa3c8baa48f76c56f0e8ace4c6eb` |
| `src/pcx/Diagnostics/StorageDiagnostics.ps1` | `c200aa3b22b6b0a70462f0ef945816d04bff7b139eda1a16b9dd9e7735826747` |
| `src/pcx/Diagnostics/ThermalDiagnostics.ps1` | `fa6c031f635740db27ae84b475fb8ec1a4da14bc483eba14390cd11cdef0ded0` |
| `src/pcx/Pcx.psm1` | `70a26ec81a9724dd6983288cc670734e7b8ced2b6bc9a42cda535073da6536af` |
| `src/pcx/Providers/FileProvider.ps1` | `2ac92e728dc16b29bb8be5372726519d70d8cee5b0ac8ab5c24aa91d30dd4348` |
| `src/pcx/Providers/ProviderCommon.ps1` | `bd2683b07abcbe08c0ab129d3dbb5e255e2bc08f2fe33923d6464d97c2f6accc` |
| `src/pcx/Providers/RegistryProvider.ps1` | `29e7158db7c8a653a33306407810c0db101d69becaa0ceb06ffcce2cc370ad98` |
| `src/pcx/Providers/ServiceProvider.ps1` | `7454af4b0730575b873b5b9430fd2491a05beaee1099c4c32bf34f30d48da090` |
| `src/pcx/Providers/TaskProvider.ps1` | `45e95ae88ab23162672cb51a222eae8ed47bb8b3b9607859ea3009f5b038a0ca` |
| `tests/.pcx-test-root` | `73ac940c134563e9289ce42015960367da8f72cc143f0282560744a8c2afe0ed` |
| `tests/E2E/DeepDiscovery.Tests.ps1` | `a9ca0965a5f0abd1a0a7c03308bc8b25eac4f63b0270eafc7c8a1cddb2b9de2c` |
| `tests/E2E/Replay.Tests.ps1` | `40326a800b7552ecdbf903eee4e4686068e3c6adb010d52634ed59a0794ae0ec` |
| `tests/E2E/AgentProposals.Tests.ps1` | `14cef1502ffb1a97eda68d857b5031ca38016847f262831b2ce4e2dad66c6f35` |
| `tests/fixtures/environment/deep-discovery/probe.json` | `f5256d5a8e6f90a9af38995fec8c6a5cc85c552b32ca739d87091a56b982fa55` |
| `tests/fixtures/environment/desktop/machine.json` | `07aa71ed01dd5127931734b16a285177420069728f58186734ad97ef399af3b1` |
| `tests/fixtures/environment/desktop/state.json` | `696e08146c0c10430dbcc85e809564db3deaabb9c74a0078ec30c4360da5fd2a` |
| `tests/fixtures/environment/managed/machine.json` | `1b3402a0d933bc2c02cc334f18493066835cc3194551b6619f61f7ce182a36f5` |
| `tests/fixtures/environment/managed/state.json` | `83b13104562287f8965e9902049cb2265761db6c7a09dd7f0c0568c0bd25686f` |
| `tests/fixtures/environment/s-mode/machine.json` | `5709b89831b31cb621ad82c715766c121bfeff7da453fe62bf32e5d6e7cb82da` |
| `tests/fixtures/environment/s-mode/state.json` | `51ba4a02bcc173fe69077ac6add66c1fda321b797b829f00f05dfbf36ab3d13a` |
| `tests/fixtures/proposals/agent-discovered.json` | `2bd763792461559585c0be818ff1319d2101c9f7f59fdd3338f46b1f4137a81d` |
| `tests/Pester/Property/PcxRoundTrip.Tests.ps1` | `2669a87100b36e8f3a8e7575ff3483630a043a1b3a432f5809178622495f4b40` |
| `tests/Pester/Unit/PcxApply,Queue.Tests.ps1` | `f219d08493295d2bc32ab6e6dacd62858fc7d9f773a684bd0a8f7f85e3b71700` |
| `tests/Pester/Unit/PcxApplyFileSkip.Tests.ps1` | `50fb147788a020e34e16cb5d25549266be7431a435652c8703f28dd6f78d6b0b` |
| `tests/Pester/Unit/PcxCatalog.Tests.ps1` | `ce6781df21e078f47527b5bb69fd3d5ca6e0215c146e194de620e8cfa001a4d5` |
| `tests/Pester/Unit/PcxCliProbe.Tests.ps1` | `9c795d3eaa65cfe8d168faa18e09e3e05880900afd8eb3ab813780bfde35c5dd` |
| `tests/Pester/Unit/PcxCollectors.Tests.ps1` | `462a57e444ac4d1837185a2c5f1751390b67189b56a98fad493af101bc647940` |
| `tests/Pester/Unit/PcxCore.Tests.ps1` | `1ed73193fbae8ee0f708769f661ec7ccc03457a7c96e2a906a1bae7262736367` |
| `tests/Pester/Unit/PcxDiagnostics.Tests.ps1` | `5007d2e591ae0a4511a0ea7a4e06cfb10fe96a536797d5794fff6d399f6f5311` |
| `tests/Pester/Unit/PcxEnvironment.Tests.ps1` | `03cbed79628f48c70740543b5988e754e162a7af7980ae84106b32ca765511d1` |
| `tests/Pester/Unit/PcxEvidence.Tests.ps1` | `5448f6ae79115fbfd4c072776ca9df188997013b4e276b5c0230018d10fb0a7a` |
| `tests/Pester/Unit/PcxFindings.Tests.ps1` | `e74e8bd2fe923288c0b679c953e61295665ffe9353e85c3e49acaee813cc403b` |
| `tests/Pester/Unit/PcxPlan.Tests.ps1` | `2301a8c884dd3699237ec4ac7ced8e93b5b4bce5af303488c6a3b745a70b4832` |
| `tests/Pester/Unit/PcxPlatform.Tests.ps1` | `13a72ff69db06d7e3e43dec6c470e22ce9294d1499f722163fb6abfbd75e1421` |
| `tests/Pester/Unit/PcxPolicy.Tests.ps1` | `c2b568631099b5372f6c3906358f4725f21212a0bc7bbc546444e44b6747ef77` |
| `tests/Pester/Unit/PcxProbe.Tests.ps1` | `b61e2c7dfe3330b334df0a35dc6eb85aa022cb80823cb5c3bbee2462280ca0fa` |
| `tests/Pester/Unit/PcxProviders.Tests.ps1` | `f4df3b19790702b91cdf3adc60fab3fb0fd132435cf969630b02184dc6188c41` |
| `tests/Pester/Unit/PcxSafety.Tests.ps1` | `f30379861de22701e03424111c255b9c659470d706d84d319348e4916cb4456e` |
| `tests/Pester/Unit/PcxSkeleton.Tests.ps1` | `1be7e81d14765327096c79e456fa6ac06d1aa382b3c2a8dd3fec6eb8135d2007` |
| `tests/Pester/Unit/PcxSnapshot.Tests.ps1` | `ec3363df54abe044295dca5e0c3e102dda98149fddb05c04499f0af260f37d43` |
| `tests/Pester/Unit/PcxTable.Tests.ps1` | `188b4ab6d8855f8a49cea3840e359d82c28239781140bd199a92cecf015ddf3c` |
| `tests/Pester/Unit/PcxText.Tests.ps1` | `77c5960ed2f411f8891ee33db243e17e46279b1ff493b17d47897697f72e448a` |
| `tests/Pester/Unit/PcxTune.Tests.ps1` | `88c049309abd532cbc26bc9569324e40af82c544a721095f29a57f9c95d6d772` |
| `tests/Pester/Unit/PcxUndo.Tests.ps1` | `16b1ddc0c1b1ce7cd216bf5b9eb16a321e779ada9f4b4a428aa6c0740a1322cc` |
| `tests/run.ps1` | `607bb9067c1c5e70051fceb84576b6decebbe7ff8c9f57ff2aed17e01cbcb64b` |
| `tests/TestAdapter/PcxPlatform.Test.ps1` | `3964fbaab27bb5701d10c08658fbc4f11e8dc17434d5240d44bfcf4e57668247` |

Compare one file with:

```
(Get-FileHash -LiteralPath <path> -Algorithm SHA256).Hash
```

The test suite verifies the whole table against the working tree and fails the
build when a hash drifts, when a listed path is missing, when a binary appears or
when an install-time path such as `.omo/` is listed.

## Run the tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
pwsh -NoProfile -File tests/run.ps1
```

The suite is fixture-only. It sets a sticky `PCX_TEST_RUN=1`, swaps in the JSON test
adapter and refuses to write to the live OS. See `SAFETY.md`.
