# Contributing / Участие

Small, reproducible contributions are welcome. Open an issue for a substantial change before introducing a new dependency, provider, data format or user flow. Current app scope uses **OpenRouter only**.

## Development

1. Fork and create a focused branch.
2. Use Xcode 26+ / macOS 26 SDK and Python 3. Run `make verify`.
3. For panel/settings changes, also run `make ui-smoke` on a Mac with a GUI.
4. Explain the concrete problem, changed behavior, checks and limitations in your PR.

Preserve original audio independently of networking, immediate Stop cancellation, segment order and genuine repetitions. Do not silently change existing exports or credential identifiers. Do not claim better recognition from code tests alone: document the dataset, independent reference, protocol and comparison.

Never commit keys, private recordings, transcripts, session folders or private evaluation reports. Use authored synthetic fixtures for reproducible tests. **Paid API evaluations are explicit operations**, outside local verification; do not send someone else's recording without permission.

The interface currently uses Russian strings; keep code, identifiers and comments in English. Keep README.md and README.ru.md aligned when user-facing behavior changes.

## По-русски

Небольшие воспроизводимые изменения приветствуются. Для существенной доработки сначала опишите задачу в issue. Текущая интеграция — только OpenRouter. Перед PR выполните `make verify`, для интерфейса — также `make ui-smoke`. Опишите проблему, поведение после изменения, проверки и ограничения.

Не нарушайте независимую запись аудио, немедленный Stop, порядок реплик и настоящие повторы. Не добавляйте ключи и пользовательские данные. Платные прогоны выполняются отдельно и только на разрешённом материале. Синхронизируйте английский и русский README.

Contributions are submitted under the repository's [MIT license](LICENSE).
