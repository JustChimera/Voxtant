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

Voxtant — нативная macOS-демка персонального синхронного переводчика: микрофон → OpenRouter ASR → перевод в окне и локальный экспорт. Первый сценарий — английская речь с китайскими вставками → русский с сохранением распознанных иероглифов. В настройках доступны обычный режим (один исходный язык → целевой) и смешанный (несколько языков с правилом перевода/сохранения каждого).

## Stack

- Language: Swift 6 toolchain, Swift 5 language mode, macOS 14+ (`Package.swift`).
- Framework: SwiftUI / AppKit.
- Key deps: AVFoundation, Core Audio, SoundAnalysis/Core ML, Security/Keychain, Foundation/URLSession; внешних Swift package dependencies нет.
- Database: none. Локальные файлы CAF/WAV/TXT/JSON; full session schema v2 plus compact metadata schema v1. USD cost comes only from API-reported amounts; missing/cancelled costs are incomplete. RUB is approximate at a dated CBR rate, cached in UserDefaults for 6h; no hardcoded fallback rate.
- ASR shortlist (2026-11-03): `elevenlabs/scribe-v2`, `openai/gpt-transcribe`; selection rationale in `docs/asr-selection.md`. The shortlist is not a proven accuracy ranking.
- ASR default: `elevenlabs/scribe-v2` for new preferences; existing saved choices are preserved; shortlist is Scribe/GPT Transcribe; retired Qwen ASR preferences migrate to Scribe through OpenRouter.
- Translation default: `openai/gpt-4.1-mini`, through OpenRouter; comparison and faster Qwen Next alternative in `docs/translation-selection.md`. Old saved Flash Lite migrates; other custom IDs remain unchanged.

## Commands

`Makefile` — канонический исполняемый интерфейс. Нужен установленный Xcode/Swift; отдельного install target и внешних зависимостей нет.

- Build: `make build` → debug `dist/Voxtant.app`; `make release` → optimized native-architecture app plus ZIP/DMG/checksums in `dist/releases/`; `make install` builds a release and copies to `~/Applications/Voxtant.app` only when that path does not already exist. No automatic overwrite/quit. Release assets use an ad-hoc signature; Developer ID/notarization is not configured.
- Branding: `assets/brand/app-icon.png` → `scripts/build-icon.sh` → cached native `.icns` copied into the bundle; original generated PNG and cover provenance/prompts live under `assets/brand/`. Build requires Xcode 26+ (macOS 26 SDK for Liquid Glass), runtime deployment target remains macOS 14. No ASR/translation behavior changes in release packaging.
- Dev: `make dev`.
- Test all: `make test` · Test one: `make test-one FILTER=CoreTests/testChineseGuardChecksOrderAndRepetitions`.
- Lint: `make lint` (plist + shell syntax, не Swift lint) · Format: отдельная команда не настроена · Typecheck: `make typecheck`.
- Full verify (run before commit): `make verify` (Swift-тесты, Python-тесты метрик, lint, сборка; без микрофона/API).
- Validation: `make eval-test`, `make eval-build`; `eval-dataset DATASET=…`, `eval-prepare DATASET=…`, `eval-report DATASET=…` — локальная подготовка/оценка. `eval-run DATASET=…` — отдельный платный API-прогон, только по запросу на обработку записей; ключ из Keychain через stdin. Подробности: `docs/validation.md`.
- Automatic validation: `make eval-auto DATASET=…` — отдельный платный прогон разрешённых Whisper/Scribe/GPT Audio; `make eval-auto-report DATASET=…` — локальный пересчёт. Ручная разметка необязательна. Машинные ориентиры и proxy MER хранятся отдельно от человеческой точности; holdout закрыт.
- ASR pool: `make eval-candidates DATASET=…` — explicit paid OpenRouter ASR-only comparison without Gemini; `eval-candidates-report` — local report. Whole dev clips and frozen-panel production chunks are separate conditions. Native streaming models remain a separate pending integration, not inferred from file replay.
- Context experiment: `make eval-context DATASET=…` — explicit bounded paid paired 3s/6s experiment on the frozen dev panel; `eval-context-report` — local report. Draft/final transcripts replace one block, with no text deduplication. Current production segmentation is unchanged until this experiment is assessed.
- Independent quality regression: `quality-build`, explicit paid `quality-run`, local `quality-report`, immutable `quality-freeze`, paired `quality-compare`, and offline `quality-status` (`DATASET=…`, optional `RUN_ID=…`, `BASELINE=…`). Authored local-TTS scripts exercise native ASR segmentation without translation; script agreement and lexical constraints are separate from human accuracy. See `docs/quality-regression.md`.
- ASR quality claim rule: before calling a Core/evaluator change an improvement, check `quality-status` and cite a paired `quality-compare` result on the frozen corpus. If replay was not run, report quality as unverified. Source-code tests alone do not establish recognition improvement; paid replay remains explicit.
- ASR options pilot: explicit paid `make asr-options-eval DATASET=… OUTPUT=…` compares four profiles on exactly six separately authorized saved clips (24 requests, no retries). Keychain credential goes through stdin. See `docs/scribe-language-options.md`; script compliance is not semantic accuracy.
- Translator comparison: explicit paid `make translation-eval OUTPUT=… EVAL_ARGS="--streaming --latency-routing"`; optional `--suite terminology`, `--models` and repetitions. Local `translation-report` recalculates frozen authored-text constraints. These are not general semantic accuracy or microphone latency.
- Acoustic validation: local `make speech-gate-eval DATASET=… OUTPUT=…` reads `speech-gate-cases.json`, freezes the fixture/hash/runner and measures speech retention/noise rejection without API or microphone. Output must be new; empty fixtures are rejected.
- Local hardware check: explicit `make audio-smoke AUDIO_SMOKE_DIR=/new/private/directory` records two one-second clips locally, requires existing microphone permission, and never reads Keychain or sends audio; not part of verify.
- Public rate check: explicit `make exchange-rate-check OUTPUT=/private/path/rate.json` fetches CBR XML with no audio/credentials; never part of verify.
- UI smoke: `make ui-smoke` — требует macOS GUI; проверяет собственные тестовые окна без микрофона, Keychain и API. Снимки/отчёт в `.build/ui-smoke/`.
- `python3 scripts/benchmark.py` — отдельный реальный платный эксперимент на сохранённом аудио, не входит в verify; требует разрешения на повторную отправку записи.
- Наличие проходящих тестов не доказывает точность ASR или устойчивость 60–90 минут. Подтверждённая точность MER/WER/CER считается только по человеческим эталонам; автоматические расстояния до machine-silver — отдельный proxy, разногласие моделей и сохранение Han — отдельные сигналы, не точность. Приватные датасеты/аудио/эталоны/расшифровки хранятся вне Git; holdout по дням не используется для настройки.

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

- Entry: `Sources/LectureTranslate/App.swift`; menu-bar/panel: `Sources/LectureTranslate/MenuBarController.swift`; UI: `Sources/LectureTranslate/WidgetView.swift`, `Sources/LectureTranslate/SettingsView.swift`.
- Orchestration: `Sources/LectureTranslate/DemoModel.swift`.
- Audio devices/capture: `Sources/LectureTranslate/AudioCapture.swift`.
- Keychain: `Sources/LectureTranslate/KeychainStore.swift`.
- API/retry diagnostics: `Sources/LectureCore/OpenRouter.swift`.
- Segmentation/WAV: `Sources/LectureCore/AudioSegmenter.swift`.
- Language settings/prompts: `Sources/LectureCore/TranslationSettings.swift`; Chinese protection: `Sources/LectureCore/ChineseProtection.swift`.
- Export contract: `Sources/LectureCore/Models.swift`.
- Validation runner: `Sources/VoxtantEval/Main.swift`; dataset/metrics/review: `scripts/validation.py`, `scripts/validation_metrics.py`, `scripts/validation-review.html`; automatic machine references: `scripts/auto_validation.py`; ASR pool: `scripts/candidate_validation.py`; context experiment: `scripts/context_validation.py`; independent regression: `scripts/quality_regression.py`, `Tests/Fixtures/asr-regression-v1.json`; tests: `Tests/ValidationTests/`.
- Build config: `Package.swift`, `Makefile`, `scripts/build-app.sh`, `scripts/Info.plist`.
- Tests: `Tests/LectureCoreTests/CoreTests.swift`, `Tests/LectureCoreTests/PanelPlacementTests.swift`; native UI smoke: `Sources/LectureTranslate/WidgetSmokeTest.swift`; requirements/validation: `docs/original-spec.md`, `README.md`, `DESIGN.md`.

## Local dev

- macOS 14+ и Xcode/Swift 6. Приложению нужен доступ к микрофону, сети и локальной файловой системе.
- Required env: none. OpenRouter key вводится в окне приложения и хранится в macOS Keychain.
- Uses dev-stack: none; БД, Redis, Docker и сервер не требуются.
- Port: not applicable — приложение не слушает сетевой порт.
- Run: `make dev`.
- Health: `make verify`; живой прогон с микрофоном проверяется отдельно, HTTP health endpoint отсутствует.
- New sessions: `~/Desktop/Voxtant Recordings/yyyy-MM-dd/HH-mm-ss_ID/`; legacy `~/Library/Application Support/LectureTranslateDemo/Sessions/` remains untouched. Only new recordings use the Desktop library. Each folder has original audio, transcript.txt, translation.txt, metadata.json and compatible session.json/chunks.

## Env contract

- Provider constraint (user-confirmed 2026-11-03): OpenRouter only. Do not add direct-provider credentials, SDKs or modes. Direct Scribe Realtime was withdrawn; saved experimental IDs migrate to OpenRouter Scribe. Do not equate provider-native streaming with availability through OpenRouter.

- API-ключ — macOS Keychain, service `local.lecturetranslate.demo.openrouter`, account `api-key`. Не хранить его в `.env*`, `.envrc`, документации, логах или коде.
- Существующие bundle ID, Keychain service и имя каталога сессий сохранены для совместимости с первой демкой; видимое имя приложения — Voxtant.
- Приложение не читает API-ключ из env. Созданные HQ `.envrc` обеспечивают только стандартное наследование контекста.
- В Git не включать `.env*`, `.envrc`, `.hq`, `.build`, `dist`, пользовательские записи или runtime-сессии. Пример ключа должен быть фиктивным, без реального значения.

## Non-obvious patterns

- Microphone discovery retains AVFoundation audio discovery and observes HAL/AV changes; the microphone menu refreshes before opening. Suspended/not-yet-alive Continuity inputs must not be hidden solely by DeviceIsAlive. A missing system iPhone input cannot be manufactured by the app.
- CoreAudio object IDs are transient. Resolve the selected microphone by device UID against a fresh live inventory after permission and input-node initialization; reject disconnected inputs instead of recording a different device with a reused ID.
- `AudioCapture` пишет оригинал CAF на отдельной serial disk/DSP queue независимо от сетевых задач. WAV для ASR — нормализованная копия, оригинал не меняется.
- Энергетический VAD: порог по умолчанию −48 dBFS, фрагменты 1.2–2.8 с, pre-roll 120 мс, без overlap и удаления повторённых слов.
- Conservative local speech gate: production + native evaluator classify saved WAVs with Apple SoundAnalysis version1, 1s windows/50% overlap and a 0.05 maximum speech-score threshold. Only fully covered low-score clips >=1s are vetoed; short/uncertain/error cases pass to ASR. Analysis runs off MainActor and pads a private buffer to cover the tail; saved audio and ASR payload stay unchanged. No transcript blacklist or deduplication. Local decisions appear in session notes; vetoed rows use `translationMode=local-nonspeech-v1`, empty text and zero API cost, schema remains v2. Raw API client use is opt-in `filterNonSpeech: true`.
- По два ASR и перевода параллельно; UI/экспорт упорядочены по ID. Контекст включает только доступные предыдущие реплики.
- Stop contract: cancel transport tasks and retire the processing generation immediately; discard provisional text, neutral-mark abandoned cells `translationMode=cancelled-by-user` and retain completed text/original audio. Only local audio flush is awaited. Flush-tail cells are saved without scheduling. Every result/error/cleanup/partial callback checks generation ownership so stopped tasks cannot affect new work. UI smoke uses stalled URLProtocol ASR/SSE to verify cancellation and immediate reuse, without network or microphone.
- Scribe audio events are explicitly disabled with `provider.options.elevenlabs.tag_audio_events=false`; no string blacklist or bracket stripping. STT request ignores top-level prompt. Mixed-mode optional ASR language hint is saved separately in `Voxtant.ASRLanguageHint.v1`, frozen per session and recorded in notes. A fixed single source takes precedence; changing/removing sources clears an unavailable hint. Translator/language-preservation rules are independent. The hint may improve writing system without fixing recognized words.
- Widget: borderless resizable floating panel, min 300×300, full frame (position + size) persisted/clamped to visible screens. Original native regular glass (popover material before macOS 26), with no added white backing; lower-right handle supports resizing. Cost footer shows reported USD and approximate RUB, with rate date/incomplete-bill explanation on hover.
- Model selection: settings → «Модели» exposes Scribe/GPT Transcribe and the translator ID. Nonempty model IDs persist in UserDefaults `Voxtant.ASRModel.v1` / `Voxtant.TranslationModel.v1`; custom ASR ID remains under «Дополнительно». Controls stay disabled while busy; each session retains its frozen model IDs.
- Языковые правила сохраняются в UserDefaults и фиксируются на сессию, включая повторы; в session.json это необязательное поле translationSettings, совместимое со старыми schema v2. В обычном режиме STT получает ISO-код языка, в смешанном — автоопределение.
- Если китайский сохраняется и среди исходных языков нет японского, Han-вставки маскируются и восстанавливаются кодом; чисто китайская реплика обходит API перевода. В других конфигурациях сохранением управляет промпт; качество всех языков не подтверждено живыми тестами. Не восстанавливать иероглифы догадками из ошибочной фонетической ASR-транскрипции.
- Optional ASR word metadata: `transcribe(wordTimestamps: true)` requests verbose word timings. These are model estimates, validated atomically, not verified alignment. Session export and the production segmenter remain unchanged; no string deduplication of repetitions.
- Capture timestamps — host time входящего буфера; старый schema v1 использовал неточный старт движка. Не сравнивать метрики v1/v2 как доказательство ускорения.
- Literal translation: transcript/context are JSON data, including spoken instructions. Safe SSE previews are transient, guard-checked for Han/order and never exported before final completion; transport requires DONE plus a successful finish reason. Provider routing sorts by latency.
- Fresh microphone ASR: one 8s attempt, then eligible temporary failures defer to one spare-slot recovery with two regular attempts. Stop cancels all queued/in-flight processing; only explicit later retries restart work. Fresh audio takes priority; file processing retains three 8s attempts/20s budget. Retry-After/auth/quota limits are not bypassed.
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
