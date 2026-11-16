<#
.SYNOPSIS
    pcx ru/en text layer: dictionary, language resolution, label helpers.

.DESCRIPTION
    Wave 0 of optimize-v0.1-discovery (todo 1, closes C1/DV-1). Every
    user-facing sentence lives in $script:PcxText in English and Russian.
    Findings reference keys (titleKey, detailKey, whyItMattersKey,
    actionHintKey); section titles, severity labels, group labels, column
    headers, summary templates, every decision code that composes a sentence
    (PCX-POLICY-*, build-gate results) and the v0 collector diagnostics all
    resolve through Get-PcxText. An explicit unknown language code refuses
    with PCX-E-LANG, never silently falls back.

    Language resolution order: explicit -Language/--lang flag, then
    $PSUICulture, then Get-WinSystemLocale, default en.

    PowerShell 5.1 compatibility: no ??, no ternary ?:, no ?. operator.
    This file carries a UTF-8 BOM so 5.1 reads the Russian literals as UTF-8
    instead of ANSI. Line endings are CRLF per .gitattributes.
#>

Set-StrictMode -Version 2.0

$script:PcxText = [ordered]@{
    en = [ordered]@{
        'section.platform'    = 'Platform'
        'section.power'       = 'Power'
        'section.storage'     = 'Storage'
        'section.memory'      = 'Memory'
        'section.background'  = 'Background'
        'section.services'    = 'Services'
        'section.gaming'      = 'Gaming'
        'section.display'     = 'Display'
        'section.network'     = 'Network'
        'section.maintenance' = 'Maintenance'
        'section.drivers'     = 'Drivers'
        'section.security'    = 'Security'
        'section.thermal'     = 'Thermal'

        'severity.critical'    = 'Critical'
        'severity.warn'        = 'Warning'
        'severity.info'        = 'Info'
        'severity.good'        = 'Good'
        'severity.unavailable' = 'Unavailable'

        'group.safe'        = 'Safe'
        'group.performance' = 'Performance & latency'
        'group.behavior'    = 'Changes behavior'
        'group.manual'      = 'Manual'
        'group.dont-touch'  = "Don't touch"

        'risk.safe'     = 'Safe'
        'risk.behavior' = 'Changes behavior'
        'risk.risky'    = 'Risky'

        'column.number'    = '#'
        'column.category'  = 'Category'
        'column.section'   = 'Section'
        'column.finding'   = 'Finding'
        'column.what'      = 'What it does'
        'column.proposal'  = 'What is proposed'
        'column.outcome'   = 'What you get'
        'column.stops'     = 'What stops working'
        'column.recommendation' = 'Recommendation'
        'column.why'       = 'Why it matters'
        'column.evidence'  = 'Evidence'
        'outcome.performance' = 'Effect not promised.'
        'fact.frees'       = 'frees {0}'
        'fact.frees.atleast' = 'frees at least {0}'
        'fact.frees.denied' = 'size unavailable without administrator rights'
        'unit.gb'          = 'GB'
        'unit.mb'          = 'MB'
        'table.none.proposals' = 'No proposals for this machine.'
        'heading.attention' = 'What needs attention'
        'heading.notes'     = 'Notes'
        'heading.good'      = 'Already good'
        'heading.nodata'    = 'No data'
        'heading.actions'   = 'What I propose'
        'fact.free'        = 'free {0} GB'
        'fact.hags-off'    = 'HAGS is off'
        'fact.game-dvr-on' = 'background recording is on'
        'fact.no-printers' = 'no printers'
        'fact.userassist'  = 'usage traces: {0}'
        'fact.prefetch'    = 'prefetch files: {0}'
        'fact.taskhistory' = 'task history events: {0}'
        'fact.tips-on'     = 'tips are on'
        'fact.ads-on'      = 'advertising ID is on'
        'fact.web-on'      = 'web results are on'
        'table.recommendation.performance' = 'Optional. Effect not promised.'
        'table.recommendation.safe' = 'Apply if you want the space back. Windows regenerates it; not restorable.'
        'table.recommendation.behavior' = 'Optional. Reversible with snapshot undo.'
        'table.recommendation.manual' = 'The agent performs it when you pick this row.'
        'table.recommendation.donttouch' = 'Do not change: pcx never touches this.'
        'table.demotion.policy' = 'Policy demoted this to Manual: {0}'
        'table.demotion.build' = 'Build gate demoted this to Manual: {0}'
        'table.caveat' = '{0} Caveat: {1}'
        'table.stops.thumbnails' = 'Explorer thumbnails are gone until Windows rebuilds the cache. Not restorable.'
        'table.stops.icon-cache' = 'Explorer icons are gone until Windows rebuilds the cache. Not restorable.'
        'table.stops.delivery-optimization-cache' = 'Cached delivery content is gone; it is downloaded again when needed. Not restorable.'
        'table.stops.windows-update-download-cache' = 'Downloaded update files are gone; Windows downloads them again on the next check. Not restorable.'
        'table.stops.diagtrack-u4' = 'DiagTrack stays disabled; diagnostics stop. The Start value is snapshotted for undo.'
        'table.stops.startup-task-u4' = 'The startup task no longer runs at sign-in. Task state is snapshotted for undo.'
        'table.stops.startup-shortcut-u4' = 'The Startup shortcut no longer runs at sign-in. It is quarantined byte for byte and restorable.'
        'table.stops.spooler-no-printers' = 'Printing stops while the spooler is disabled. The Start value is snapshotted for undo.'
        'table.stops.game-dvr' = 'Game DVR capture stays off; clips and background recording are unavailable. Values are snapshotted.'
        'table.stops.hags' = 'HAGS stays enabled; DLSS Frame Generation requires it. The previous value is snapshotted.'
        'table.stops.tips' = 'Windows tips and suggestions stop appearing. The previous value is snapshotted.'
        'table.stops.advertising-id' = 'Ad personalization is disabled. The previous value is snapshotted.'
        'table.stops.search-web' = 'Web results no longer appear in Windows Search. The previous value is snapshotted.'
        'table.stops.vbs' = 'Disabling VBS weakens protection; pcx never changes it.'
        'table.stops.managed' = 'Managed devices refuse every write; pcx leaves policy alone.'
        'table.stops.s-mode' = 'S Mode restricts writes; pcx leaves the mode alone.'
        'table.stops.hvci' = 'Disabling HVCI weakens protection; pcx never changes it.'
        'table.stops.inverse.manifest-only' = 'Deleted content is not restorable.'
        'table.stops.inverse.quarantine' = 'The item is moved to quarantine and restorable byte for byte.'
        'table.stops.inverse.snapshot' = 'Changed state is snapshotted for undo.'
        'table.stops.default' = 'Nothing from pcx.'
        'table.env.managed.label' = 'The device is managed'
        'table.env.managed.text' = 'Outlook/Intune policy owns these settings; the engine refuses every write on a managed device.'
        'table.env.smode.label' = 'The device runs in S Mode'
        'table.env.smode.text' = 'S Mode restricts registry, service, task and file writes; the engine refuses every write in S Mode.'
        'table.env.hvci.label' = 'HVCI is enabled'
        'table.env.hvci.text' = 'Memory-integrity protection is on; disabling it weakens protection and pcx never changes it.'
        'table.none.problems' = 'No problems found.'
        'apply.file.partial' = 'deleted {0} of {1} file(s); skipped {2}: {3}.'
        'apply.file.all-skipped' = 'no file could be deleted; skipped {0}: {1}.'

        'summary.line'     = 'Problems: {0} · notes: {1} · no data: {2} · already good: {3}.'
        'progress.section' = 'Scanning {0}...'
        'progress.platform'    = 'Scanning Platform...'
        'progress.power'       = 'Scanning Power...'
        'progress.storage'     = 'Scanning Storage...'
        'progress.memory'      = 'Scanning Memory...'
        'progress.background'  = 'Scanning Background...'
        'progress.services'    = 'Scanning Services...'
        'progress.gaming'      = 'Scanning Gaming...'
        'progress.display'     = 'Scanning Display...'
        'progress.network'     = 'Scanning Network...'
        'progress.maintenance' = 'Scanning Maintenance...'
        'progress.drivers'     = 'Scanning Drivers...'
        'progress.security'    = 'Scanning Security...'
        'progress.thermal'     = 'Scanning Thermal...'

        'decision.PCX-POLICY-ACL'              = 'The key is owned by TrustedInstaller; pcx never writes it.'
        'decision.PCX-POLICY-BOOTCHAIN'        = 'The key belongs to the boot chain; a wrong value can prevent the machine from booting.'
        'decision.PCX-POLICY-SECURITY'         = 'The key configures a security subsystem and is manual-only.'
        'decision.PCX-POLICY-ANTICHEAT'        = 'The target belongs to an anticheat client; modifying it can block a protected game.'
        'decision.PCX-POLICY-HKCU-DEFAULT-DENY' = 'HKCU is default-deny; the key is outside the enumerated writable subtrees.'
        'decision.PCX-POLICY-REGISTRY-VALUE'   = 'Registry writes are value-level only; a key without a value name is not writable.'
        'decision.PCX-POLICY-HKLM-VALUE'       = 'HKLM writes are value-level only; the target is not the enumerated HAGS value and no HKLM subtree is writable.'
        'decision.PCX-POLICY-HIVE'             = "The '{0}' hive is not a writable surface."
        'decision.PCX-POLICY-DRIVER'           = 'The service is a kernel driver.'
        'decision.PCX-POLICY-SERVICE-START'    = 'A service write may only set Start to 3 (Manual) or 4 (Disabled).'
        'decision.PCX-POLICY-BLAST-RADIUS'     = 'Changing the service can break dependents; blast radius cannot be ruled out.'
        'decision.PCX-POLICY-TASK-SYSTEM'      = 'Tasks under \Microsoft\Windows\ are system tasks and are never touched.'
        'decision.PCX-POLICY-TASK-ENABLE'      = 'A task write may only disable an existing task; enabling is never allowed.'
        'decision.PCX-POLICY-REPARSE'          = 'The target is a reparse point; pcx never follows one.'
        'decision.PCX-POLICY-FILE-ROLE'        = 'A file target must declare role a1 or quarantine.'
        'decision.PCX-POLICY-QUARANTINE-ROOT'  = 'A quarantine source must be inside the Startup folders (a2_roots).'
        'decision.PCX-POLICY-FILE-ROOT'        = 'An A1 target must be inside a1_roots (OS-regenerable caches only).'
        'decision.PCX-POLICY-MANAGED'          = 'The profile is managed or unknown; managed machines refuse every write.'
        'decision.PCX-POLICY-SMODE'            = 'The profile is in S Mode or unknown; a write is refused.'
        'decision.PCX-POLICY-DEVDRIVE'         = 'The profile uses a Dev Drive or is unknown; a write is refused.'
        'decision.PCX-POLICY-GRAMMAR'          = 'The target text is not valid pcx grammar: {0}.'
        'decision.PCX-POLICY-ALLOW'            = 'Allowed.'

        'build.unsupported'  = 'Build {0} is unsupported; Windows 10 2004+ (build 19041) or Windows 11 (build 22000) is required.'
        'build.verified'     = 'Build {0} is a verified {1} build.'
        'build.unverified'   = 'Build {0} is a supported {1} build but is not verified; effect not promised.'
        'build.unavailable'  = 'The detected build is unavailable; demoted to Manual.'
        'build.notanumber'   = "The detected build '{0}' is not a number; demoted to Manual."

        'scan.env.budget'        = 'The scan budget was exhausted before the environment probe could run; the environment is unavailable.'
        'scan.env.timeout'       = 'The environment probe exceeded the {0}ms scan budget and was aborted; the environment is unavailable.'
        'scan.env.error'         = 'The environment probe failed: {0}.'
        'scan.env.empty'         = 'The environment probe returned no environment; the environment is unavailable.'
        'scan.collector.timeout' = "Collector group '{0}' exceeded {1}ms and was aborted."
        'scan.collector.error'   = "Collector group '{0}' failed: {1}."
        'scan.source.nometric'   = 'collector returned no metric'
        'scan.source.budget'     = 'scan budget exhausted'
        'scan.source.timeout'    = 'collector exceeded {0}ms and was aborted'
        'scan.source.failed'     = 'collector failed'

        'finding.platform.os-build-support.title' = 'OS build support'
        'finding.platform.os-build-support.detail' = 'Whether this Windows build still receives servicing.'
        'finding.platform.uptime.title' = 'System uptime'
        'finding.platform.uptime.detail' = 'Time since the last boot; long uptimes delay pending updates.'
        'finding.platform.bios-age.title' = 'BIOS firmware age'
        'finding.platform.bios-age.detail' = 'Release date of the system firmware.'
        'finding.platform.gpu-driver-age.title' = 'GPU driver age'
        'finding.platform.gpu-driver-age.detail' = 'Release date of the installed graphics driver.'
        'finding.platform.cpu-mem-summary.title' = 'Processor and memory summary'
        'finding.platform.cpu-mem-summary.detail' = 'Installed processor and total physical memory.'
        'finding.power.pagefile-state.title' = 'Pagefile state'
        'finding.power.pagefile-state.detail' = 'Whether the paging file is system-managed and large enough.'
        'finding.power.power-plan.title' = 'Active power plan'
        'finding.power.power-plan.detail' = 'Which power scheme is currently active.'
        'finding.power.fast-startup.title' = 'Fast startup'
        'finding.power.fast-startup.detail' = 'Whether hybrid fast startup is enabled.'
        'finding.storage.system-free-space.title' = 'System drive free space'
        'finding.storage.system-free-space.detail' = 'Free space share on the system drive.'
        'finding.storage.volume-health.title' = 'Volume health'
        'finding.storage.volume-health.detail' = 'Whether volumes report errors or a dirty bit.'
        'finding.storage.top-space-consumers.title' = 'Largest space consumers'
        'finding.storage.top-space-consumers.detail' = 'Largest folders two levels below the profile roots.'
        'finding.memory.ram-usage.title' = 'Memory usage'
        'finding.memory.ram-usage.detail' = 'Share of physical memory currently in use.'
        'finding.memory.pagefile-pressure.title' = 'Pagefile pressure'
        'finding.memory.pagefile-pressure.detail' = 'Share of the paging file currently in use.'
        'finding.memory.standby-list.title' = 'Standby memory'
        'finding.memory.standby-list.detail' = 'Cached standby memory available for reuse.'
        'finding.background.process-count.title' = 'Process count'
        'finding.background.process-count.detail' = 'How many processes are running.'
        'finding.background.top-ram-processes.title' = 'Top memory processes'
        'finding.background.top-ram-processes.detail' = 'Processes using the most working set.'
        'finding.background.startup-entries.title' = 'Startup entries'
        'finding.background.startup-entries.detail' = 'Values registered under the Run keys.'
        'finding.background.scheduled-task-count.title' = 'Scheduled tasks'
        'finding.background.scheduled-task-count.detail' = 'How many scheduled tasks are registered.'
        'finding.services.auto-services.title' = 'Automatic services'
        'finding.services.auto-services.detail' = 'How many services start automatically.'
        'finding.services.third-party-services.title' = 'Third-party services'
        'finding.services.third-party-services.detail' = 'Automatic services from outside Windows.'
        'finding.services.failed-services.title' = 'Failed services'
        'finding.services.failed-services.detail' = 'Services that exited with an error.'
        'finding.gaming.game-mode.title' = 'Game Mode'
        'finding.gaming.game-mode.detail' = 'Whether Windows Game Mode is enabled.'
        'finding.gaming.hags.title' = 'Hardware GPU scheduling'
        'finding.gaming.hags.detail' = 'Whether hardware-accelerated GPU scheduling is on.'
        'finding.gaming.game-dvr.title' = 'Game DVR capture'
        'finding.gaming.game-dvr.detail' = 'Whether background game capture is enabled.'
        'finding.gaming.overlay-processes.title' = 'Overlay processes'
        'finding.gaming.overlay-processes.detail' = 'Running overlay and capture helpers.'
        'finding.gaming.vbs-hvci.title' = 'Virtualization security'
        'finding.gaming.vbs-hvci.detail' = 'Whether VBS and HVCI memory integrity are on.'
        'finding.display.monitor-count.title' = 'Connected displays'
        'finding.display.monitor-count.detail' = 'How many displays are detected.'
        'finding.display.resolution-layout.title' = 'Resolution layout'
        'finding.display.resolution-layout.detail' = 'Pixel resolution of each detected display.'
        'finding.display.audio-endpoints.title' = 'Audio endpoints'
        'finding.display.audio-endpoints.detail' = 'Detected playback and recording devices.'
        'finding.network.adapter-link-speed.title' = 'Link speed'
        'finding.network.adapter-link-speed.detail' = 'Negotiated speed of connected adapters.'
        'finding.network.dns-servers.title' = 'DNS servers'
        'finding.network.dns-servers.detail' = 'Configured DNS servers per interface.'
        'finding.network.nagle.title' = 'Nagle algorithm'
        'finding.network.nagle.detail' = 'Whether TCP Nagle batching is disabled per interface.'
        'finding.network.tcp-autotuning.title' = 'TCP auto-tuning'
        'finding.network.tcp-autotuning.detail' = 'Receive-window auto-tuning level.'
        'finding.maintenance.windows-update-age.title' = 'Last update install'
        'finding.maintenance.windows-update-age.detail' = 'Age of the last successful update install.'
        'finding.maintenance.restore-points.title' = 'Restore points'
        'finding.maintenance.restore-points.detail' = 'How many system restore points exist.'
        'finding.maintenance.pending-reboot.title' = 'Pending reboot'
        'finding.maintenance.pending-reboot.detail' = 'Whether updates or renames await a reboot.'
        'finding.drivers.driver-age.title' = 'Oldest drivers'
        'finding.drivers.driver-age.detail' = 'Oldest signed third-party driver dates.'
        'finding.drivers.problem-devices.title' = 'Problem devices'
        'finding.drivers.problem-devices.detail' = 'Devices reporting a configuration error.'
        'finding.security.defender-state.title' = 'Defender state'
        'finding.security.defender-state.detail' = 'Whether Microsoft Defender protects the machine.'
        'finding.security.firewall-state.title' = 'Firewall state'
        'finding.security.firewall-state.detail' = 'Whether the firewall profiles are enabled.'
        'finding.security.bitlocker-state.title' = 'BitLocker state'
        'finding.security.bitlocker-state.detail' = 'Whether volumes are BitLocker-protected.'
        'finding.security.tpm-state.title' = 'TPM state'
        'finding.security.tpm-state.detail' = 'Whether a TPM is present and ready.'
        'finding.security.defender-exclusions.title' = 'Defender exclusions'
        'finding.security.defender-exclusions.detail' = 'Configured Defender exclusion paths.'
        'finding.thermal.cpu-temp.title' = 'Processor temperature'
        'finding.thermal.cpu-temp.detail' = 'Best-effort processor temperature reading.'
        'finding.thermal.gpu-temp.title' = 'Graphics temperature'
        'finding.thermal.gpu-temp.detail' = 'Best-effort graphics temperature reading.'

        'error.lang.unknown' = "Unknown language code '{0}'. Supported: en, ru."
    }
    ru = [ordered]@{
        'section.platform'    = 'Платформа'
        'section.power'       = 'Питание'
        'section.storage'     = 'Хранилище'
        'section.memory'      = 'Память'
        'section.background'  = 'Фон и автозапуск'
        'section.services'    = 'Службы'
        'section.gaming'      = 'Игры'
        'section.display'     = 'Экран и звук'
        'section.network'     = 'Сеть'
        'section.maintenance' = 'Обслуживание'
        'section.drivers'     = 'Драйверы'
        'section.security'    = 'Безопасность'
        'section.thermal'     = 'Температуры'

        'severity.critical'    = 'Критично'
        'severity.warn'        = 'Предупреждение'
        'severity.info'        = 'Информация'
        'severity.good'        = 'В порядке'
        'severity.unavailable' = 'Нет данных'

        'group.safe'        = 'Безопасно'
        'group.performance' = 'Производительность и задержки'
        'group.behavior'    = 'Меняет поведение'
        'group.manual'      = 'Вручную'
        'group.dont-touch'  = 'Не трогать'

        'risk.safe'     = 'Безопасно'
        'risk.behavior' = 'Меняет поведение'
        'risk.risky'    = 'Рискованно'

        'column.number'    = '№'
        'column.category'  = 'Категория'
        'column.section'   = 'Раздел'
        'column.finding'   = 'Находка'
        'column.what'      = 'Что делает'
        'column.proposal'  = 'Что предлагается'
        'column.outcome'   = 'Что получим'
        'column.stops'     = 'Что перестанет работать'
        'column.recommendation' = 'Рекомендация'
        'column.why'       = 'Почему это важно'
        'column.evidence'  = 'Доказательство'
        'outcome.performance' = 'Эффект не обещан.'
        'fact.frees'       = 'освободит {0}'
        'fact.frees.atleast' = 'освободит не менее {0}'
        'fact.frees.denied' = 'размер недоступен без прав администратора'
        'unit.gb'          = 'ГБ'
        'unit.mb'          = 'МБ'
        'table.none.proposals' = 'Для этой машины предложений нет.'
        'heading.attention' = 'Что требует внимания'
        'heading.notes'     = 'Заметки'
        'heading.good'      = 'Уже в порядке'
        'heading.nodata'    = 'Без данных'
        'heading.actions'   = 'Что предлагаю'
        'fact.free'        = 'свободно {0} ГБ'
        'fact.hags-off'    = 'аппаратное планирование выключено'
        'fact.game-dvr-on' = 'фоновая запись включена'
        'fact.no-printers' = 'принтеров нет'
        'fact.userassist'  = 'следов использования: {0}'
        'fact.prefetch'    = 'файлов в предзагрузке: {0}'
        'fact.taskhistory' = 'событий в истории задач: {0}'
        'fact.tips-on'     = 'подсказки включены'
        'fact.ads-on'      = 'рекламный идентификатор включён'
        'fact.web-on'      = 'веб-результаты включены'
        'table.recommendation.performance' = 'По желанию. Эффект не обещан.'
        'table.recommendation.safe' = 'Применяйте, чтобы вернуть место. Windows пересоздаст данные; восстановление невозможно.'
        'table.recommendation.behavior' = 'По желанию. Откат через снимок.'
        'table.recommendation.manual' = 'Агент выполнит это, если выбрать строку.'
        'table.recommendation.donttouch' = 'Не менять: pcx этого не трогает.'
        'table.demotion.policy' = 'Политика понизила до ручного: {0}'
        'table.demotion.build' = 'Проверка сборки понизила до ручного: {0}'
        'table.caveat' = '{0} Оговорка: {1}'
        'table.stops.thumbnails' = 'Миниатюры Explorer пропадут, пока Windows не пересоздаст кэш. Не восстанавливается.'
        'table.stops.icon-cache' = 'Значки Explorer пропадут, пока Windows не пересоздаст кэш. Не восстанавливается.'
        'table.stops.delivery-optimization-cache' = 'Кэшированное содержимое доставки пропадёт; при необходимости оно скачается снова. Не восстанавливается.'
        'table.stops.windows-update-download-cache' = 'Скачанные файлы обновлений пропадут; Windows загрузит их снова при следующей проверке. Не восстанавливается.'
        'table.stops.diagtrack-u4' = 'Служба DiagTrack останется отключённой; диагностика остановится. Значение Start сохраняется в снимке для отката.'
        'table.stops.startup-task-u4' = 'Задача больше не запускается при входе в систему. Состояние задачи сохраняется в снимке для отката.'
        'table.stops.startup-shortcut-u4' = 'Ярлык больше не запускается при входе в систему. Он помещается в карантин байт-в-байт и восстанавливается.'
        'table.stops.spooler-no-printers' = 'Печать останавливается, пока спулер отключён. Значение Start сохраняется в снимке для отката.'
        'table.stops.game-dvr' = 'Запись Game DVR остаётся выключенной; клипы и фоновая запись недоступны. Значения сохраняются в снимке.'
        'table.stops.hags' = 'HAGS остаётся включённым; DLSS Frame Generation требует его. Предыдущее значение сохраняется в снимке.'
        'table.stops.tips' = 'Подсказки и советы Windows больше не появляются. Предыдущее значение сохраняется в снимке.'
        'table.stops.advertising-id' = 'Персонализация рекламы отключена. Предыдущее значение сохраняется в снимке.'
        'table.stops.search-web' = 'Веб-результаты больше не появляются в поиске Windows. Предыдущее значение сохраняется в снимке.'
        'table.stops.vbs' = 'Отключение VBS ослабляет защиту; pcx никогда его не меняет.'
        'table.stops.managed' = 'Управляемые устройства запрещают любую запись; pcx оставляет политики без изменений.'
        'table.stops.s-mode' = 'S-режим ограничивает запись; pcx оставляет режим без изменений.'
        'table.stops.hvci' = 'Отключение HVCI ослабляет защиту; pcx никогда его не меняет.'
        'table.stops.inverse.manifest-only' = 'Удалённое содержимое не восстанавливается.'
        'table.stops.inverse.quarantine' = 'Элемент перемещается в карантин и восстанавливается байт-в-байт.'
        'table.stops.inverse.snapshot' = 'Изменённое состояние сохраняется в снимке для отката.'
        'table.stops.default' = 'pcx ничего не делает.'
        'table.env.managed.label' = 'Устройство управляемое'
        'table.env.managed.text' = 'Параметры принадлежат политикам Outlook/Intune; на управляемом устройстве движок запрещает любую запись.'
        'table.env.smode.label' = 'Устройство работает в S-режиме'
        'table.env.smode.text' = 'S-режим ограничивает запись в реестр, службы, задачи и файлы; движок запрещает любую запись в S-режиме.'
        'table.env.hvci.label' = 'HVCI включён'
        'table.env.hvci.text' = 'Защита целостности памяти включена; её отключение ослабляет защиту, и pcx никогда её не меняет.'
        'table.none.problems' = 'Проблем не найдено.'
        'apply.file.partial' = 'удалено {0} из {1}; пропущено {2}: {3}.'
        'apply.file.all-skipped' = 'ни один файл не удалён; пропущено {0}: {1}.'

        'summary.line'     = 'Проблемы: {0} · заметки: {1} · без данных: {2} · в порядке: {3}.'
        'progress.section' = 'Сканирование {0}...'
        'progress.platform'    = 'Сканирование: Платформа...'
        'progress.power'       = 'Сканирование: Питание...'
        'progress.storage'     = 'Сканирование: Хранилище...'
        'progress.memory'      = 'Сканирование: Память...'
        'progress.background'  = 'Сканирование: Фон и автозапуск...'
        'progress.services'    = 'Сканирование: Службы...'
        'progress.gaming'      = 'Сканирование: Игры...'
        'progress.display'     = 'Сканирование: Экран и звук...'
        'progress.network'     = 'Сканирование: Сеть...'
        'progress.maintenance' = 'Сканирование: Обслуживание...'
        'progress.drivers'     = 'Сканирование: Драйверы...'
        'progress.security'    = 'Сканирование: Безопасность...'
        'progress.thermal'     = 'Сканирование: Температуры...'

        'decision.PCX-POLICY-ACL'              = 'Раздел принадлежит TrustedInstaller; pcx никогда его не записывает.'
        'decision.PCX-POLICY-BOOTCHAIN'        = 'Раздел относится к загрузочной цепочке; неверное значение может помешать загрузке компьютера.'
        'decision.PCX-POLICY-SECURITY'         = 'Ключ настраивает подсистему безопасности; только вручную.'
        'decision.PCX-POLICY-ANTICHEAT'        = 'Цель принадлежит античит-клиенту; изменение может заблокировать защищённую игру.'
        'decision.PCX-POLICY-HKCU-DEFAULT-DENY' = 'HKCU по умолчанию запрещён; раздел вне перечисленных записываемых подразделов.'
        'decision.PCX-POLICY-REGISTRY-VALUE'   = 'Запись в реестр только на уровне значений; раздел без имени значения недоступен для записи.'
        'decision.PCX-POLICY-HKLM-VALUE'       = 'Запись в HKLM только на уровне значений; цель — не перечисленное значение HAGS, записываемых подразделов HKLM нет.'
        'decision.PCX-POLICY-HIVE'             = "Куст '{0}' недоступен для записи."
        'decision.PCX-POLICY-DRIVER'           = 'Служба является драйвером ядра.'
        'decision.PCX-POLICY-SERVICE-START'    = 'Запись службы допускает только Start 3 (вручную) или 4 (отключена).'
        'decision.PCX-POLICY-BLAST-RADIUS'     = 'Изменение службы может нарушить зависимые; радиус поражения исключить нельзя.'
        'decision.PCX-POLICY-TASK-SYSTEM'      = 'Задачи в \Microsoft\Windows\ — системные; pcx их не трогает.'
        'decision.PCX-POLICY-TASK-ENABLE'      = 'Запись задачи допускает только отключение существующей задачи; включение запрещено.'
        'decision.PCX-POLICY-REPARSE'          = 'Цель — точка повторной обработки; pcx никогда не следует по ним.'
        'decision.PCX-POLICY-FILE-ROLE'        = 'Файловая цель должна объявлять роль a1 или quarantine.'
        'decision.PCX-POLICY-QUARANTINE-ROOT'  = 'Источник карантина должен быть внутри папок автозапуска (a2_roots).'
        'decision.PCX-POLICY-FILE-ROOT'        = 'Цель A1 должна быть внутри a1_roots (только восстанавливаемые ОС кэши).'
        'decision.PCX-POLICY-MANAGED'          = 'Профиль управляемый или неизвестен; на управляемых машинах запрещена любая запись.'
        'decision.PCX-POLICY-SMODE'            = 'Профиль в S-режиме или неизвестен; запись запрещена.'
        'decision.PCX-POLICY-DEVDRIVE'         = 'Профиль использует Dev Drive или неизвестен; запись запрещена.'
        'decision.PCX-POLICY-GRAMMAR'          = 'Текст цели — неверная грамматика pcx: {0}.'
        'decision.PCX-POLICY-ALLOW'            = 'Разрешено.'

        'build.unsupported'  = 'Сборка {0} не поддерживается; требуется Windows 10 2004+ (сборка 19041) или Windows 11 (сборка 22000).'
        'build.verified'     = 'Сборка {0} — проверенная сборка {1}.'
        'build.unverified'   = 'Сборка {0} — поддерживаемая сборка {1}, но не проверена; эффект не обещан.'
        'build.unavailable'  = 'Обнаруженная сборка недоступна; понижено до ручного.'
        'build.notanumber'   = "Обнаруженная сборка '{0}' — не число; понижено до ручного."

        'scan.env.budget'        = 'Бюджет сканирования исчерпан до запуска зонда окружения; окружение недоступно.'
        'scan.env.timeout'       = 'Зонд окружения превысил бюджет сканирования {0} мс и был остановлен; окружение недоступно.'
        'scan.env.error'         = 'Зонд окружения завершился ошибкой: {0}.'
        'scan.env.empty'         = 'Зонд окружения не вернул окружение; окружение недоступно.'
        'scan.collector.timeout' = "Группа сборщиков '{0}' превысила {1} мс и была остановлена."
        'scan.collector.error'   = "Группа сборщиков '{0}' завершилась ошибкой: {1}."
        'scan.source.nometric'   = 'сборщик не вернул метрику'
        'scan.source.budget'     = 'бюджет сканирования исчерпан'
        'scan.source.timeout'    = 'сборщик превысил {0} мс и был остановлен'
        'scan.source.failed'     = 'сборщик завершился ошибкой'

        'finding.platform.os-build-support.title' = 'Поддержка сборки'
        'finding.platform.os-build-support.detail' = 'Получает ли эта сборка обновления обслуживания.'
        'finding.platform.uptime.title' = 'Время работы'
        'finding.platform.uptime.detail' = 'Время с последней перезагрузки; долгая работа откладывает обновления.'
        'finding.platform.bios-age.title' = 'Возраст прошивки'
        'finding.platform.bios-age.detail' = 'Дата выпуска системной прошивки.'
        'finding.platform.gpu-driver-age.title' = 'Возраст видеодрайвера'
        'finding.platform.gpu-driver-age.detail' = 'Дата выпуска установленного видеодрайвера.'
        'finding.platform.cpu-mem-summary.title' = 'Процессор и память'
        'finding.platform.cpu-mem-summary.detail' = 'Установленный процессор и объём физической памяти.'
        'finding.power.pagefile-state.title' = 'Файл подкачки'
        'finding.power.pagefile-state.detail' = 'Управляется ли файл подкачки системой и достаточен ли его размер.'
        'finding.power.power-plan.title' = 'Схема питания'
        'finding.power.power-plan.detail' = 'Какая схема питания сейчас активна.'
        'finding.power.fast-startup.title' = 'Быстрый запуск'
        'finding.power.fast-startup.detail' = 'Включён ли гибридный быстрый запуск.'
        'finding.storage.system-free-space.title' = 'Свободное место'
        'finding.storage.system-free-space.detail' = 'Доля свободного места на системном диске.'
        'finding.storage.volume-health.title' = 'Здоровье томов'
        'finding.storage.volume-health.detail' = 'Сообщают ли тома об ошибках или флаге проверки.'
        'finding.storage.top-space-consumers.title' = 'Крупнейшие потребители'
        'finding.storage.top-space-consumers.detail' = 'Крупнейшие папки на два уровня ниже корневых.'
        'finding.memory.ram-usage.title' = 'Использование памяти'
        'finding.memory.ram-usage.detail' = 'Доля занятой физической памяти.'
        'finding.memory.pagefile-pressure.title' = 'Нагрузка на подкачку'
        'finding.memory.pagefile-pressure.detail' = 'Доля используемого файла подкачки.'
        'finding.memory.standby-list.title' = 'Резервная память'
        'finding.memory.standby-list.detail' = 'Кэшированная резервная память, готовая к повторному использованию.'
        'finding.background.process-count.title' = 'Число процессов'
        'finding.background.process-count.detail' = 'Сколько процессов запущено.'
        'finding.background.top-ram-processes.title' = 'Процессы по памяти'
        'finding.background.top-ram-processes.detail' = 'Процессы с наибольшим рабочим набором.'
        'finding.background.startup-entries.title' = 'Элементы автозапуска'
        'finding.background.startup-entries.detail' = 'Значения в разделах автозапуска.'
        'finding.background.scheduled-task-count.title' = 'Задачи планировщика'
        'finding.background.scheduled-task-count.detail' = 'Сколько запланированных задач зарегистрировано.'
        'finding.services.auto-services.title' = 'Автозапуск служб'
        'finding.services.auto-services.detail' = 'Сколько служб запускается автоматически.'
        'finding.services.third-party-services.title' = 'Сторонние службы'
        'finding.services.third-party-services.detail' = 'Автоматические службы не из состава системы.'
        'finding.services.failed-services.title' = 'Службы с ошибками'
        'finding.services.failed-services.detail' = 'Службы, завершившиеся с ошибкой.'
        'finding.gaming.game-mode.title' = 'Игровой режим'
        'finding.gaming.game-mode.detail' = 'Включён ли игровой режим системы.'
        'finding.gaming.hags.title' = 'Аппаратное планирование'
        'finding.gaming.hags.detail' = 'Включено ли аппаратное планирование графического процессора.'
        'finding.gaming.game-dvr.title' = 'Фоновая запись игр'
        'finding.gaming.game-dvr.detail' = 'Включена ли фоновая запись игры.'
        'finding.gaming.overlay-processes.title' = 'Процессы оверлеев'
        'finding.gaming.overlay-processes.detail' = 'Запущенные помощники оверлея и захвата.'
        'finding.gaming.vbs-hvci.title' = 'Виртуализация безопасности'
        'finding.gaming.vbs-hvci.detail' = 'Включены ли защита виртуализации и целостность памяти.'
        'finding.display.monitor-count.title' = 'Подключённые экраны'
        'finding.display.monitor-count.detail' = 'Сколько экранов обнаружено.'
        'finding.display.resolution-layout.title' = 'Разрешения экранов'
        'finding.display.resolution-layout.detail' = 'Разрешение каждого обнаруженного экрана в пикселях.'
        'finding.display.audio-endpoints.title' = 'Звуковые устройства'
        'finding.display.audio-endpoints.detail' = 'Обнаруженные устройства воспроизведения и записи.'
        'finding.network.adapter-link-speed.title' = 'Скорость подключения'
        'finding.network.adapter-link-speed.detail' = 'Согласованная скорость подключённых адаптеров.'
        'finding.network.dns-servers.title' = 'Серверы имён'
        'finding.network.dns-servers.detail' = 'Настроенные серверы имён для каждого интерфейса.'
        'finding.network.nagle.title' = 'Алгоритм Нейгла'
        'finding.network.nagle.detail' = 'Отключена ли групповая передача для каждого интерфейса.'
        'finding.network.tcp-autotuning.title' = 'Автонастройка сети'
        'finding.network.tcp-autotuning.detail' = 'Уровень автонастройки окна приёма.'
        'finding.maintenance.windows-update-age.title' = 'Последнее обновление'
        'finding.maintenance.windows-update-age.detail' = 'Давность последней успешной установки обновлений.'
        'finding.maintenance.restore-points.title' = 'Точки восстановления'
        'finding.maintenance.restore-points.detail' = 'Сколько точек восстановления системы существует.'
        'finding.maintenance.pending-reboot.title' = 'Ожидание перезагрузки'
        'finding.maintenance.pending-reboot.detail' = 'Ждут ли обновления или переименования перезагрузки.'
        'finding.drivers.driver-age.title' = 'Старейшие драйверы'
        'finding.drivers.driver-age.detail' = 'Даты старейших подписанных сторонних драйверов.'
        'finding.drivers.problem-devices.title' = 'Устройства с ошибками'
        'finding.drivers.problem-devices.detail' = 'Устройства, сообщающие об ошибке настройки.'
        'finding.security.defender-state.title' = 'Состояние защитника'
        'finding.security.defender-state.detail' = 'Защищает ли машину встроенный антивирус.'
        'finding.security.firewall-state.title' = 'Состояние брандмауэра'
        'finding.security.firewall-state.detail' = 'Включены ли профили брандмауэра.'
        'finding.security.bitlocker-state.title' = 'Шифрование дисков'
        'finding.security.bitlocker-state.detail' = 'Зашифрованы ли тома.'
        'finding.security.tpm-state.title' = 'Модуль безопасности'
        'finding.security.tpm-state.detail' = 'Есть ли готовый к работе модуль безопасности.'
        'finding.security.defender-exclusions.title' = 'Исключения защитника'
        'finding.security.defender-exclusions.detail' = 'Настроенные пути исключений защитника.'
        'finding.thermal.cpu-temp.title' = 'Температура процессора'
        'finding.thermal.cpu-temp.detail' = 'Ориентировочное показание температуры процессора.'
        'finding.thermal.gpu-temp.title' = 'Температура графики'
        'finding.thermal.gpu-temp.detail' = 'Ориентировочное показание температуры графики.'

        'error.lang.unknown' = "Неизвестный код языка '{0}'. Поддерживаются: en, ru."
    }
}

function Get-PcxLanguageCodeFromCultureName {
    # Maps 'ru-RU'/'ru' to 'ru', 'en-US'/'en' to 'en', anything else to $null.
    param([Parameter(Mandatory = $false)][string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $short = $Name.Trim().ToLowerInvariant()
    if ($short -match '^([a-z]{2})([-_][a-z]+)?$') {
        $short = $Matches[1]
    }
    if ($short -eq 'ru' -or $short -eq 'en') { return $short }

    return $null
}

function Resolve-PcxLanguage {
    <#
    .SYNOPSIS
        Resolves the report language: flag, then UI culture, then system locale.

    .DESCRIPTION
        An explicit -Requested code ('en', 'ru', 'ru-RU', ...) is validated
        strictly: an unknown code throws PCX-E-LANG and never falls back.
        Auto-detection (empty -Requested) walks $PSUICulture, then
        Get-WinSystemLocale, and defaults to 'en'; an unrecognized culture
        simply moves to the next source.
    #>
    param([Parameter(Mandatory = $false)][string] $Requested)

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $code = Get-PcxLanguageCodeFromCultureName -Name $Requested
        if ($null -ne $code) { return $code }
        throw [System.ArgumentException]::new('PCX-E-LANG: ' + (Get-PcxText -Key 'error.lang.unknown' -Language 'en' -FormatArgs @($Requested)))
    }

    $auto = Get-PcxLanguageCodeFromCultureName -Name ([string]$PSUICulture)
    if ($null -ne $auto) { return $auto }

    try {
        $systemLocale = Get-WinSystemLocale
        $auto = Get-PcxLanguageCodeFromCultureName -Name ([string]$systemLocale.Name)
        if ($null -ne $auto) { return $auto }
    }
    catch {
    }

    return 'en'
}

function Get-PcxText {
    <#
    .SYNOPSIS
        Returns one dictionary sentence for a key in the given language.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $false)][string] $Language = 'en',
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $FormatArgs = @()
    )

    $code = Resolve-PcxLanguage -Requested $Language
    $table = $script:PcxText[$code]
    if ($null -eq $table -or -not $table.Contains($Key)) {
        throw [System.Collections.Generic.KeyNotFoundException]::new("PCX-E-TEXT: no text key '$Key' for language '$code'.")
    }

    $template = [string]$table[$Key]
    $args = @($FormatArgs)
    if ($args.Count -gt 0) {
        return ($template -f $args)
    }

    return $template
}

function Get-PcxSeverityLabel {
    <#
    .SYNOPSIS
        Returns the severity label (critical/warn/info/good/unavailable).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Severity,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $name = ([string]$Severity).Trim().ToLowerInvariant()
    return Get-PcxText -Key ('severity.' + $name) -Language $Language
}

function Get-PcxSectionTitle {
    <#
    .SYNOPSIS
        Returns the section title for one of the 13 registry ids.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Section,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $id = ([string]$Section).Trim().ToLowerInvariant()
    return Get-PcxText -Key ('section.' + $id) -Language $Language
}
