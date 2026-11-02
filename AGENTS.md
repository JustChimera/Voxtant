# Repo — Voxtant


## Context hierarchy

| Path | Read when |
|---|---|
| `../AGENTS.md` | Cross-repo work, understand role in voxtant product |
| `../../AGENTS.md` | Company workflow and secrets conventions |
| `../docs/ARCHITECTURE.md` | Deep product architectural context |
| `docs/design.md` | Repo-specific design decisions, patterns |
| `docs/adr/*.md` | Repo-level architectural decisions |

Rule: load parent / docs only when task requires.

Baseline rules live in `~/dotfiles/agent-profiles/BASELINE.md` and are loaded
through the agent profile. Platform references live in
`~/dotfiles/docs/platform/`; read them only when the task needs that workflow.

## What this repo does

Voxtant — нативная macOS-демка персонального синхронного переводчика: микрофон → OpenRouter ASR → перевод в окне и локальный экспорт. Первый сценарий — английская речь с китайскими вставками → русский с сохранением распознанных иероглифов.

## Stack

- Language: Swift 6 toolchain, Swift 5 language mode, macOS 14+ (`Package.swift`).
- Framework: SwiftUI / AppKit.
- Key deps: AVFoundation, Core Audio, Security/Keychain, Foundation/URLSession; внешних Swift package dependencies нет.
- Database: none. Локальные файлы CAF/WAV/TXT/JSON, schema v2.
- ASR defaults: `qwen/qwen3-asr-1.7b`; опционально `google/gemini-2.5-flash` через OpenRouter.
- Translation default: `google/gemini-2.5-flash-lite`, также через OpenRouter.

## Commands

`Makefile` — канонический исполняемый интерфейс. Нужен установленный Xcode/Swift; отдельного install target и внешних зависимостей нет.

- Build: `make build` → `dist/Voxtant.app`.
- Dev: `make dev`.
- Test all: `make test` · Test one: `make test-one FILTER=CoreTests/testChineseGuardChecksOrderAndRepetitions`.
- Lint: `make lint` (plist + shell syntax, не Swift lint) · Format: отдельная команда не настроена · Typecheck: `make typecheck`.
- Full verify (run before commit): `make verify` (локальные HTTP-заглушки, без микрофона/API).
- `python3 scripts/benchmark.py` — отдельный реальный платный эксперимент на сохранённом аудио, не входит в verify; требует разрешения на повторную отправку записи.
- Наличие проходящих тестов не доказывает точность ASR или устойчивость 60–90 минут.

## Testing contract

- Prefer stable Make targets: `install`, `dev`, `test`, `test-one`, `lint`, `format`, `typecheck`, `verify`.
- `verify` must be local and non-destructive: no migrations, deploys, broad cleanup, or external state mutation.
- When adding a new test suite, runner, package manager, or quality gate, update `Makefile` first and then update this `AGENTS.md` section.
- If no automated tests exist yet, document that fact here. Adding a Makefile or test target is a separate implementation task, not a prerequisite for filling context.
- Optional UI labels live in `.agents/commands.toml`; do not duplicate logic there if a Make target is enough.

## Platform references

- Git workflow: `~/dotfiles/docs/platform/git-workflow.md`
- Secrets/env: `~/dotfiles/docs/platform/secrets-env.md`
- Local infra (dev-stack): `~/dotfiles/services/dev-stack/README.md` (canonical; live list: `dev-stack urls`)
- ML/quant: `~/dotfiles/docs/platform/ml-quant-workflow.md`

## WikiPedik memory

- Read path is automatic when `docs/knowledge/hot.md` exists: SessionStart injects it into new Codex/Claude sessions.
- When you find a durable root cause, production gotcha, failed approach, reusable rule, informal decision, or cross-repo invariant, use `lesson-append` to append one structured capture to `docs/knowledge/_inbox.md`.
- Before the final answer, run a memory checkpoint: if this task produced a durable root cause, production gotcha, failed approach, reusable rule, informal decision, or cross-repo invariant, use `lesson-append`; if not, write nothing.
- Do not edit curated wiki pages directly (`lessons.md`, `gotchas.md`, `debugging-stories.md`, product/shared pages). Use `wiki sync chimera/voxtant/Voxtant` from the shell for curator review.
- If `docs/knowledge/_inbox.md` is missing, tell the user to run `wiki bootstrap chimera voxtant Voxtant`.
- Skip low-signal notes. A capture must explain what happened, why it happened, and the reusable rule.

## Key files

- Entry/UI: `Sources/LectureTranslate/App.swift`.
- Orchestration: `Sources/LectureTranslate/DemoModel.swift`.
- Audio devices/capture: `Sources/LectureTranslate/AudioCapture.swift`.
- Keychain: `Sources/LectureTranslate/KeychainStore.swift`.
- API/retry diagnostics: `Sources/LectureCore/OpenRouter.swift`.
- Segmentation/WAV: `Sources/LectureCore/AudioSegmenter.swift`.
- Chinese protection: `Sources/LectureCore/ChineseProtection.swift`.
- Export contract: `Sources/LectureCore/Models.swift`.
- Build config: `Package.swift`, `Makefile`, `scripts/build-app.sh`, `scripts/Info.plist`.
- Tests: `Tests/LectureCoreTests/CoreTests.swift`; requirements/validation: `docs/original-spec.md`, `README.md`.

## Local dev

- macOS 14+ и Xcode/Swift 6. Приложению нужен доступ к микрофону, сети и локальной файловой системе.
- Required env: none. OpenRouter key вводится в окне приложения и хранится в macOS Keychain.
- Uses dev-stack: none; БД, Redis, Docker и сервер не требуются.
- Port: not applicable — приложение не слушает сетевой порт.
- Run: `make dev`.
- Health: `make verify`; живой прогон с микрофоном проверяется отдельно, HTTP health endpoint отсутствует.
- Original sessions: `~/Library/Application Support/LectureTranslateDemo/Sessions/`; экспорт через Save.

## Env contract

- API-ключ — macOS Keychain, service `local.lecturetranslate.demo.openrouter`, account `api-key`. Не хранить его в `.env*`, `.envrc`, документации, логах или коде.
- Существующие bundle ID, Keychain service и имя каталога сессий сохранены для совместимости с первой демкой; видимое имя приложения — Voxtant.
- Приложение не читает API-ключ из env. Созданные HQ `.envrc` обеспечивают только стандартное наследование контекста.
- В Git не включать `.env*`, `.envrc`, `.hq`, `.build`, `dist`, пользовательские записи или runtime-сессии. Пример ключа должен быть фиктивным, без реального значения.

## Non-obvious patterns

- `AudioCapture` пишет оригинал CAF на отдельной serial disk/DSP queue независимо от сетевых задач. WAV для ASR — нормализованная копия, оригинал не меняется.
- Энергетический VAD: порог по умолчанию −48 dBFS, фрагменты 1.2–2.8 с, pre-roll 120 мс, без overlap и удаления повторённых слов.
- По два ASR и перевода параллельно; UI/экспорт упорядочены по ID. Контекст включает только доступные предыдущие реплики.
- Китайские вставки маскируются перед переводом и восстанавливаются кодом; чисто китайская реплика обходит API перевода. Не восстанавливать иероглифы догадками из ошибочной фонетической ASR-транскрипции.
- Capture timestamps — host time входящего буфера; старый schema v1 использовал неточный старт движка. Не сравнивать метрики v1/v2 как доказательство ускорения.
- HTTP retries ограничены числом попыток/бюджетом и учитывают Retry-After; время и ошибки каждой попытки сохраняются без ключа.
- Не переименовывать legacy storage/Keychain identifiers без продуманного переноса существующих данных.

## Boundaries

- Не трогать без отдельной просьбы: `.env*`, `.envrc`, пользовательские записи и Keychain values. Секреты и исходный звук не коммитить.
- Ask first: новая внешняя зависимость, изменение модели хранения/совместимости с существующими сессиями, повторная отправка сохранённого голоса во внешний API.
- Сохранять запись при сетевых ошибках; не заявлять слово-в-слово timestamps по границам аудиофрагментов.
- Не менять текущую задачу на конспектирование, аккаунты, облачную синхронизацию или другие исключённые из MVP функции.
- Правила Git и компании наследуются из родительского контекста; push — по явной просьбе пользователя.
- Дополнительных ограничений сверх исходного ТЗ и общих правил нет.

## Lessons (organic)

(no entries yet)
