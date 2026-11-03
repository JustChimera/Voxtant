# Scribe events and Chinese priority — 2026-11-03

## Findings

The user reported Scribe as fast in live use, Qwen as slow, and Chinese snippets
appearing in phonetic Cyrillic/Latin rather than Han. Local session inspection
confirmed Scribe outputs `[ambient noise]`, `[background noise]`, `[outro jingle]`
and `[外国语]` before translation. GPT also returned phonetic Cyrillic and Georgian
on Chinese-sounding examples; the text translator then preserved/translated those
already-misrecognized strings. This is an ASR issue, not reconstructable reliably
from phonetic text alone.

Scribe's API enables `tag_audio_events` by default. OpenRouter explicitly supports
this option under `provider.options.elevenlabs`, so production now sends false.
This suppresses sound annotations at their source; no bracket stripping, word
blacklist or transcript rewriting is used. Genuine spoken “outro jingle” remains
speech. The local acoustic gate remains enabled independently.

## Authorized real-audio pilot

The user authorized six saved short clips, up to 24 paid requests. Four profiles
(Scribe auto/zh and GPT auto/zh) were tested once per clip, rotating profile order,
using the native client with an 8s/one-attempt limit and no retries. Scribe events
were false in both profiles. The speech gate was deliberately disabled for this
probe so the options themselves received identical WAV bytes, including noise.
All **24/24** requests succeeded; no further private-audio requests were sent.

| Profile | Median response, seconds | Chinese-role clips containing Han |
|---|---:|---:|
| Scribe auto | 1.555 | 2/4 |
| Scribe zh | 1.546 | 4/4 |
| GPT auto | 1.011 | 0/4 |
| GPT zh | 1.111 | 3/4 |

These counts measure **writing system, not recognition accuracy**. No independent
word-level human reference exists. The cases were selected because they failed;
they cannot estimate general real-world accuracy. Four Chinese-role clips, one
English control and one historical outro control form this small diagnostic panel.

On one clip GPT changed `Ниши лавшима.` to `你是老师吗？` with zh. Other outputs still
contained wrong/unverified characters. Scribe auto produced `你好，你是李老师吗？`
where zh produced `你好，你是老水吗？`; the hint is not uniformly better. One GPT
profile stayed in English despite zh. Do not infer success merely from Han presence.

Both models retained the English control with zh. One short English example does
not justify forcing Chinese globally. Scribe returned empty text on the historical
outro WAV with events false; the old event-enabled result was `[outro jingle]`.
That historical output is not a same-time event-enabled paired control.

## Shipped behavior

- New preferences default to Scribe v2 for practical live use. Existing GPT/custom choices persist; retired Qwen ASR preferences migrate to Scribe. The current selectable shortlist is Scribe/GPT.
- Mixed-mode settings offer «Приоритетный язык»: Automatic (default) or one of the
  configured source languages. It sends an ISO language hint to transcription,
  independently of target language and per-language translate/preserve rules.
- A fixed source in ordinary mode takes precedence over a mixed-mode hint.
  Removing its source language clears the saved hint. Busy controls are disabled.
- The preference lives in UserDefaults `Voxtant.ASRLanguageHint.v1`, freezes with
  the session and is recorded in existing session notes; export schema remains v2.
- Translator remains `openai/gpt-4.1-mini`; literal Han preservation and permanent
  Stop cancellation are unchanged. No automatic slow second ASR pass is added.

The public OpenRouter Scribe integration documents an allowlist of STT options;
unsupported `keyterms`, transcript editing or a generic top-level prompt must not
be assumed to work. Direct ElevenLabs offers more options, but requires a separate
credential/integration. No direct integration is introduced here.

## Validation and limits

Local contract tests verify events=false, optional language hint, single-source
precedence, unchanged repeats and translation settings. UI smoke checks preference
persistence, lock while busy and reset after source removal, plus existing Stop.
The frozen synthetic quality scorer is unchanged; **the full synthetic API replay
has not been rerun for this new request profile**. No new general ASR quality or
production-readiness claim is made. Current metric/source status explicitly records
that an updated replay is pending. Real accent-sensitive word accuracy remains open.

Private files: `voxtant-asr-options-v1/options-v1` contains frozen fixture/hash,
runner/source fingerprints, individual attempts, results and the full Russian
report; original session outputs are retained separately as historical baselines.

Reproduction: `make asr-options-eval DATASET=/private/six-clips OUTPUT=/new/private/run`.
This is an explicit paid operation, separate from verify and requiring authorization
for those clips. The wrapper reads Keychain to process stdin, never arguments/env.

References: [OpenRouter ElevenLabs options](https://openrouter.ai/blog/announcements/elevenlabs-on-openrouter/),
[OpenRouter STT contract](https://openrouter.ai/docs/guides/overview/multimodal/stt),
[ElevenLabs transcription options](https://elevenlabs.io/docs/api-reference/speech-to-text/convert).
