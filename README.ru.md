# pcx

**Оптимизатор Windows 10/11 для ИИ-агентов.**

[English](README.md) · **Русский**

[![Лицензия: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1_%7C_7-blue?style=flat-square)](INSTALL.md)
[![Windows 10 | 11](https://img.shields.io/badge/Windows-10_%7C_11-blue?style=flat-square)](INSTALL.md)
[![Pester 613](https://img.shields.io/badge/Pester-613_passing-brightgreen?style=flat-square)](tests/run.ps1)
[![автообновлений нет](https://img.shields.io/badge/auto--update-never-red?style=flat-square)](SAFETY.md)

<!-- i18n: ## English lives in this file; ## Русский lives in README.ru.md. -->

## Что это такое

pcx — навык для OpenCode, Claude Code, Codex, Cursor и VS Code. Он сканирует
Windows 10/11 только на чтение, показывает одну таблицу измеренных предложений
и применяет только выбранные строки. Агент никогда не скрывает находку, отказ
или сбой.

## Что он делает

- Сканирует 13 областей ПК только на чтение и печатает краткую сводку.
- Показывает одну таблицу: точная цель, риск и измеренный размер или состояние.
- Применяет только выбранные строки, по одному изменению за раз.
- Сообщает, что изменилось и как это откатить.

## Зачем это нужно

- Каждая строка измерена; отсутствующая цель или нечитаемое значение не
  превращаются в выдуманный ноль.
- Типизированные изменения откатываются снимком; безопасные удаления кэша честно
  говорят, что невосстановимы.
- Загрузочная цепочка, службы безопасности, драйверы ядра, античиты, управляемые
  устройства, S Mode и Dev Drive не трогаются.

## Как это работает

1. Введите `/pcx` (или скажите «оптимизируй ПК»). Команда сама запускает скан;
   больше ни одной команды pcx вводить не нужно.
2. Агент печатает краткую сводку по машине, затем одну таблицу: номер, риск,
   точное действие, цель и измеренный размер или состояние. Строка появляется
   только если цель есть на этой машине.
3. Агент задаёт один короткий вопрос только с номерами. До ответа ничего не
   применяется.
4. Вы выбираете. Агент применяет строки по одной и завершает одним отчётом: что
   изменилось и как это откатить, что осталось и почему.

## Установка

Вставьте ссылку на репозиторий в ИИ-агента и скажите «установи». Агент прочитает
`SKILL.md`, выполнит `INSTALL.md`, запустит `pcx doctor` и остановится.

Или клонируйте:

```text
git clone https://github.com/nzeronfourme/pcx pcx
pwsh -File .\pcx\pcx.ps1 doctor
```

Куда кладётся папка навыка (имя каталога обязано быть `pcx`):

| Среда | Глобально | Уровень проекта |
|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\skills\pcx\` | `.opencode/skills/pcx/` |
| Claude Code | `%USERPROFILE%\.claude\skills\pcx\` | `.claude/skills/pcx/` |
| Codex, Cursor, VS Code | `%USERPROFILE%\.agents\skills\pcx\` | `.agents/skills/pcx/` |

Для OpenCode скопируйте `command/pcx.md` в
`%USERPROFILE%\.config\opencode\command\pcx.md`, а `agent/pcx.md` — в
`%USERPROFILE%\.config\opencode\agent\pcx.md`. Команда работает под этим агентом,
который запрещает task-инструмент. `INSTALL.md` пинит каждый поставляемый файл
SHA-256; `doctor` только читает. В Windows PowerShell 5.1 используйте
`powershell -NoProfile -ExecutionPolicy Bypass -File <path>\pcx.ps1 doctor`.

## Отчёт

Настоящий вывод, строки сокращены:

```text
## What I propose

| # | Category | What is proposed | What you get |
|---|---|---|---|
| 1 | 🟢 Safe | Delete Windows.old | Frees 6.37 GB. Not reversible. |
| 2 | 🟠 Changes behavior | Turn hibernation off | Frees 12.7 GB. Restore with powercfg /h on. |
| 3 | 🟠 Changes behavior | Quarantine OneDrive.lnk | OneDrive stops starting. The shortcut is restorable. |
```

Строки появляются только для целей, которые есть на машине и имеют измеренный
размер или состояние. Агент добавляет свои находки в ту же таблицу, продолжая
нумерацию, и задаёт один вопрос только с номерами. 🟢 не теряет функций; 🟠
останавливает конкретную функцию и откатывается снимком; 🔴 может повлиять на
стабильность, обновления или безопасность.

## Что он проверяет

13 разделов диагностики дают 45 фиксированных id находок. `pcx probe` отвечает
на 8 семейств: `reg:`, `svc:`, `task:`, `file:`, `counter:`, `event:`, `intent:`,
`environment:`. Агент также исследует машину сам: процессы, автозапуск, задачи,
хранилище, сеть, обновления, драйверы, питание, события, безопасность. Скан
только читает и не требует администратора.

## Что он может менять

13 типизированных действий: 4 безопасных удаления кэша (`thumbnails`,
`icon-cache`, `delivery-optimization-cache`, `windows-update-download-cache`),
2 снимка производительности (`game-dvr`, `hags`), 7 снимков поведения
(`diagtrack-u4`, `startup-task-u4`, `startup-shortcut-u4`,
`spooler-no-printers`, `tips`, `advertising-id`, `search-web`). JSON-каталог в
`config/actions/` — источник правды; см. `references/catalog.md`.

8 заметок только для чтения измеряются, но никогда не выполняются: Manual
`windows-old`, `wer`, `temp`, `hiberfil`; Don't touch `vbs`, `anticheat`,
`vbs-hvci`, `defender-exclusions`.

Сборки: автоприменение проверено только на 26100/26200. На других поддерживаемых
клиентских сборках каждое действие остаётся выбираемым с оговоркой «не проверено
на сборке <n>; эффект не обещан»; на неподдерживаемых (Server, Server Core, до
19041) все действия понижаются до Manual.

## Откат

- Типизированные действия откатываются точно: `pcx undo --item <id>`,
  `--plan <id>` или `--last` возвращают снимок и выходят с 0 только при равенстве
  SHA-256. Код 3 означает отказ, ничего не откатывалось.
- Безопасные удаления кэша невосстановимы; pcx пишет манифест с путём, размером и
  SHA-256 всего удалённого.
- У изменённого вне pcx автоматического отката нет; агент говорит, как откатить,
  или что это невозможно, до выполнения.

## Требования

| Требование | Подробно |
|---|---|
| ОС | Windows 10 19041+ или Windows 11 22000+. |
| Оболочка | PowerShell 5.1 или 7. |
| Только для тестов | Pester 5 или новее. |

## Известные ограничения

- Занятые файлы кэша пропускаются и перечисляются пофайлово.
- Нет обещания FPS или задержки. Строки производительности говорят **effect not
  promised**; процент, который эта машина не измеряла, не появляется.
- Скан ничего не пишет без `--out`. Реальную запись включают только `tune --apply`
  и `undo`, и никогда при `PCX_TEST_RUN`.
- Нет автообновлений, бинарников и PATH-шима. Установка всегда ваше действие.
- Нет автоматизации категории C; такие находки остаются ручными, защищённые цели
  остаются под запретом.

## Документация

`SKILL.md` (сценарий агента) · `INSTALL.md` ([EN](INSTALL.md)) · `SAFETY.md` ([EN](SAFETY.md)) · `command/pcx.md` · `references/method.md` · `references/catalog.md`.

Тесты: `pwsh -NoProfile -File tests/run.ps1`.

## Лицензия

MIT, см. `LICENSE`.
