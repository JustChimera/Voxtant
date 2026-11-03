# Security and private data / Безопасность

Voxtant is an experimental personal app, not a security-reviewed production product. Current support is best-effort for the latest source and 0.1.x demo builds; no response-time commitment is offered.

**Do not publish API keys, private audio, transcripts, session JSON or identifying recording details in issues.** Remove secrets and use a synthetic reproducer. If an API key was exposed, revoke it in OpenRouter first.

Use GitHub's private vulnerability reporting for this repository if available. If it is unavailable, open only a minimal issue asking for a private reporting channel; do not include exploit details or private data publicly. There is no separate security inbox configured.

Keys are stored in macOS Keychain. The app sends audio/text through OpenRouter and the selected providers; local storage does not make cloud processing offline. There is no bundled key, built-in account backend or app telemetry. Release builds are ad-hoc signed and not notarized.

По-русски: не прикладывайте ключи, приватные записи, транскрипции и JSON сессий к публичным issue. Для воспроизведения используйте синтетические данные. Утёкший ключ сначала отзовите в OpenRouter. При наличии используйте приватный канал GitHub; иначе запросите его без публикации деталей уязвимости. Поддержка экспериментальной версии — по возможности, без SLA.
