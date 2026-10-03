<div align="center">

<img src="Orbit/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Orbit">

# Orbit

**Центр управления проектами для разработчика, который работает вместе с ИИ-агентами.**

План недели по проектам · здоровье проектов · сессии Claude Code и Codex · состояние git — в одном нативном окне macOS.

![Version](https://img.shields.io/badge/version-0.6.1-C8F169?style=flat-square&labelColor=15171A)
![Platform](https://img.shields.io/badge/macOS-15%2B-ECEDEF?style=flat-square&logo=apple&logoColor=white&labelColor=15171A)
![Swift](https://img.shields.io/badge/SwiftUI-Swift%205-F59E5B?style=flat-square&logo=swift&logoColor=white&labelColor=15171A)
![Local first](https://img.shields.io/badge/данные-локально-5AD48A?style=flat-square&labelColor=15171A)

<img src="design/exports/png/01-week-dashboard.png" width="900" alt="Экран «Неделя»">

</div>

---

## Зачем

Когда параллельно ведёшь несколько проектов и в каждом работают агенты, легко потерять нить: где агент застрял вчера, какая ветка отстала от `main`, что лежит незакоммиченным третий день и за какой проект браться в пятницу. Orbit собирает это сам — из git и логов агентов — и предлагает план на неделю.

## Возможности

<table>
<tr>
<td width="50%" valign="top">

### 📅 Неделя
Проект в фокусе на сегодня с целью дня, последняя сессия агента, состояние git и следующие шаги. План недели с фактическими часами — проекты перетаскиваются из сайдбара на нужный день.

</td>
<td width="50%" valign="top">

### 🗓 Планировщик
Сетка «проекты × дни». Автоплан учитывает здоровье проектов, сигналы, ваш ритм (часы по дням, проектов в день) и закреплённые дни. «Другой вариант» — пересобрать.

</td>
</tr>
<tr>
<td valign="top">

### 🤖 Сессии агентов
Claude Code, Codex и Aider: что сделано, где застрял, сколько токенов и тестов, ход сессии и транскрипт. «Продолжить с контекстом» открывает ту же сессию в терминале.

</td>
<td valign="top">

### 🌿 Git
Ветки, ahead/behind, отставание от `main` и конфликты, график коммитов «агенты / вы», заброшенные ветки. Коммит с готовым сообщением прямо из приложения.

</td>
</tr>
<tr>
<td valign="top">

### 🔔 Сигналы
Незакоммиченное дольше суток, ветка отстала, агент откатывает правки, падают тесты, проект простаивает. Каждое правило — тумблер; сигнал закрывается сам, когда проблема ушла.

</td>
<td valign="top">

### 🌅 Фоновый режим
Проверка каждые 15 минут, утренняя сводка в 9:00, автоплан по воскресеньям в 20:00, уведомления macOS. Orbit живёт в строке меню, когда окно закрыто.

</td>
</tr>
</table>

## 🧠 ИИ-анализ

Orbit пишет выводы по проектам, следующие шаги, цель дня, разбор сессий агентов, сообщения коммитов и брифы для агентов. Модель выбирается в **Настройках → Анализ** (<kbd>⌘</kbd> <kbd>,</kbd>) или в онбординге:

| Провайдер | Как работает | Что нужно |
| --- | --- | --- |
| **Claude · подписка** | `claude -p` в фоне — тот же аккаунт, что в Claude Code | Claude Code с входом в Pro / Max |
| **Claude API** | Messages API, structured outputs | API-ключ Anthropic |
| **Codex · подписка** | `codex exec` | Codex CLI с входом в ChatGPT |
| **Ollama** | локальная модель | `ollama serve` |
| **OpenAI-совместимый** | `/chat/completions` | Base URL и ключ (OpenAI, OpenRouter, LM Studio…) |
| **Эвристики** | правила без модели | — (по умолчанию) |

В модель уходят только **сводки**: названия файлов и веток, заголовки и итоги сессий, сообщения коммитов, ошибки тестов. Исходный код не отправляется — кроме диффа для сообщений коммитов, если включить это в настройках. Ключи хранятся в связке ключей macOS. Ответы кэшируются, а проект переанализируется только когда что-то изменилось и не чаще раза в 6 часов — подписка расходуется экономно.

## Экраны

| | |
| :---: | :---: |
| <img src="design/exports/png/02-project-detail.png" alt="Проект"> | <img src="design/exports/png/03-projects.png" alt="Проекты"> |
| **Проект** — здоровье, сессии, git, дни работы | **Проекты** — карточки и время по проектам |
| <img src="design/exports/png/04-agent-sessions.png" alt="Сессии агентов"> | <img src="design/exports/png/05-git.png" alt="Git"> |
| **Сессии агентов** — итог, затыки, рекомендация | **Git** — коммиты, репозитории, ветки |
| <img src="design/exports/png/06-signals.png" alt="Сигналы"> | <img src="design/exports/png/07-week-planner.png" alt="Планировщик"> |
| **Сигналы** — правила мониторинга | **Планировщик** — план на неделю |

<details>
<summary><b>Онбординг и первый запуск</b></summary>
<br>

| | |
| :---: | :---: |
| <img src="design/exports/png/08-onboarding-1-repos.png" alt="Репозитории"> | <img src="design/exports/png/09-onboarding-2-agents.png" alt="Агенты"> |
| <img src="design/exports/png/10-onboarding-3-rhythm.png" alt="Ритм недели"> | <img src="design/exports/png/11-week-first-launch.png" alt="Первый запуск"> |

</details>

> Скриншоты — макеты из `design/` (Pencil). Приложение сверстано по ним и показывает ваши реальные проекты.

## Установка

Скачайте **`Orbit-X.Y.Z.dmg`** из [последнего релиза](https://github.com/Tolib-N8/Project-control-center/releases/latest), откройте и перетащите Orbit в «Программы». Дальше приложение обновляется само.

<img src="scripts/dmg/preview.png" width="480" alt="Окно установки Orbit">

> Orbit не нотарифицирован Apple, поэтому первый запуск — правый клик → «Открыть».

## Сборка из исходников

Нужны **Xcode 26+** и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Orbit build
open ~/Library/Developer/Xcode/DerivedData/Orbit/Build/Products/Release/Orbit.app
```

При первом запуске онбординг найдёт репозитории в выбранных папках, источники логов агентов и спросит ритм недели.

### Обновления

Orbit обновляется сам: при запуске и каждые 6 часов он проверяет [последний релиз](https://github.com/Tolib-N8/Project-control-center/releases/latest), показывает, что нового, и по одной кнопке скачивает архив, проверяет его контрольную сумму, версию и подпись, заменяет себя и перезапускается. Вручную — «Orbit → Проверить обновления…». Настройки — в «Настройки → Общие → Обновления». Для самообновления Orbit должен лежать в папке, куда можно писать (например, «Программы»).

> [!TIP]
> Держите DerivedData вне `~/Documents`: iCloud добавляет файлам метаданные, и подпись падает с ошибкой *«resource fork, Finder information, or similar detritus not allowed»*.

## Откуда берутся данные

Всё читается **локально**, код никуда не отправляется. Состояние приложения — в `~/.orbit`.

| Данные | Источник |
| --- | --- |
| Ветка, ahead/behind, незакоммиченное, отставание от `main`, конфликты | `git status --porcelain=v2`, `git rev-list`, `git merge-tree` |
| Коммиты и их автор (агент или вы) | `git log` + трейлеры `Co-Authored-By` + окна сессий агентов |
| Сессии **Claude Code** | `~/.claude/projects/<папка>/*.jsonl` |
| Сессии **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` + `session_index.jsonl` |
| Сессии **Aider** | `.aider.chat.history.md` в корне репозитория |
| Здоровье, план, сигналы | локальные эвристики — `Orbit/Services` |
| Выводы, шаги, разбор сессий | выбранная модель — `Orbit/Services/AI`, или эвристики |

Логи парсятся один раз и кэшируются по размеру и времени изменения файла, поэтому повторное обновление занимает около секунды.

<details>
<summary><b>Как считается здоровье проекта</b></summary>
<br>

Шкала 0–100. Штрафы: изменения не закоммичены дольше суток, ветка отстаёт от `main`, конфликты, красные тесты в последней сессии, простой больше недели, доля незавершённых и откаченных сессий. Бонусы: завершённые сессии и коммиты за неделю. ≥ 75 — «в хорошей форме», 50–74 — «требует внимания», < 50 — «критично». Логика — [`HealthEngine.swift`](Orbit/Services/HealthEngine.swift).

</details>

## Горячие клавиши

| | |
| --- | --- |
| <kbd>⌘</kbd> <kbd>1</kbd>…<kbd>5</kbd> | Неделя · Проекты · Сессии · Git · Сигналы |
| <kbd>⌘</kbd> <kbd>R</kbd> | Обновить данные |
| <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>P</kbd> | Запланировать неделю |
| <kbd>⌘</kbd> <kbd>,</kbd> | Настройки (провайдер ИИ-анализа) |

## Структура проекта

```
Orbit/
├── App/         точка входа, AppState, строка меню
├── Design/      токены темы и общие компоненты
├── Models/      проекты, git, сессии, план, сигналы
├── Services/    GitService, парсеры сессий, движки здоровья/выводов/сигналов, Planner
│   └── AI/      провайдеры моделей и промпты анализа
└── Features/    Неделя · Проекты · Сессии агентов · Git · Сигналы · Онбординг
OrbitTests/      парсеры на фикстурах, git на временном репо, планировщик и сигналы
design/          макеты Pencil и экспорты
```

## Разработка

```sh
# тесты
xcodebuild test -project Orbit.xcodeproj -scheme Orbit \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Orbit -destination 'platform=macOS'

# прогон на ваших реальных репозиториях
ORBIT_SMOKE=1 xcodebuild test …
```

Debug-сборка умеет сохранять скриншоты экранов без разрешения на запись экрана; `--data-dir` подменяет `~/.orbit`, так что реальные данные не трогаются. Шаг `frames:projects` в `--screens` сохраняет три кадра посреди перехода, флаг `--reduce-motion` (ставьте его последним) включает режим «Уменьшить движение»:

```sh
Orbit.app/Contents/MacOS/Orbit --data-dir /tmp/orbit-data --snapshot /tmp/shots --auto-onboard
```

Версия задаётся в одном месте — `MARKETING_VERSION` в [`project.yml`](project.yml). История изменений — в [CHANGELOG.md](CHANGELOG.md).

**Выпуск версии.** Добавьте раздел `## [X.Y.Z]` в CHANGELOG, закоммитьте и запустите:

```sh
scripts/release.sh X.Y.Z            # версия, коммит, тег, push, сборка, .dmg и релиз на GitHub
scripts/release.sh X.Y.Z --install  # …и установить сборку в «Программы»
```

В релиз уходят два файла: оформленный **`.dmg`** для установки (окно собирает `scripts/make-dmg.sh` по `scripts/dmg/`) и **`.zip`** для встроенного обновления. Установленные копии Orbit увидят релиз при следующей проверке обновлений.

## Дорожная карта

- [x] **0.1** — все экраны на реальных данных, эвристики вместо ИИ
- [x] **0.2** — ИИ-анализ: Claude по подписке, Claude API, Codex, Ollama, OpenAI-совместимые
- [x] **0.3** — анимации и переходы, поддержка «Уменьшить движение»
- [x] **0.4** — анимация запуска с логотипом
- [x] **0.5** — встроенные обновления и выпуск версии одной командой
- [ ] GitHub: открытые PR и статусы CI через `gh`
- [ ] Уведомления в Telegram и на почту
- [ ] Чаты Cursor
