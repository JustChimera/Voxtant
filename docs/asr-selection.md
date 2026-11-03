# ASR shortlist — 2026-11-03

Current decision: **Scribe v2 and GPT Transcribe only**. The user removed Qwen ASR
after slow live behavior. It is excluded from UI, candidate requests, context and
future quality runs; saved Qwen ASR choices migrate to Scribe. Historical evidence
below is retained. The new two-model cohort requires a new quality baseline.

## Historical three-model evaluation

The user confirmed Qwen3 ASR 1.7B, ElevenLabs Scribe v2 and OpenAI GPT Transcribe
as the quality shortlist for the next phase. They are selectable in app
settings → «Модели» and are the default evaluation pool. No accuracy winner or production
segmentation change has been accepted. Access remains through OpenRouter.

- **Qwen3 ASR 1.7B**: control for mixed English/Mandarin recognition. On three
  mixed clips with machine-silver references it had 9.9% mixed-token distance and
  12.8% Han distance. The samples contain only 47 reference Han characters, so these
  are selective proxies, not verified accuracy. The tested OpenRouter route had
  substantial latency/timeouts; raising timeout to 30s produced two ~19s responses.
- **Scribe v2**: candidate for a practical live path. In the seven-model experiment
  all 25 whole clips and 53 production chunks returned nonempty text without HTTP
  failures. Inspected mixed outputs retained English and Chinese; independent
  accuracy is unknown because the frozen silver protocol depends on Scribe.
- **GPT Transcribe**: candidate for larger-context recognition. Some whole mixed
  outputs retained both languages; 21/53 production chunks returned empty text.
  Its frozen silver references also share the OpenAI GPT lineage, so they cannot
  establish this candidate's independent accuracy.

MAI Transcribe 2 remains a secondary candidate; the aggregate six-reference score
is helped by non-Chinese examples. On the three mixed references Qwen was closer,
and one MAI output omitted a full Chinese insertion. Deepgram, GPT-4o Transcribe,
Whisper Turbo and Gemini are outside the current quality shortlist. Historical
results and explicitly requested expanded comparison remain available.

## Next acceptance question

Does a provisional 3s line corrected using 6s acoustic context reduce missing or
corrupted Chinese spans while keeping first text useful? Run the fixed dev panel
with a paired 3s control, retain genuine repetitions, and assess missing text,
failures and reference coverage separately. Do not assume an observed agreement
with a model's own longer output is ground truth. Ship a new segmentation default
only after assessing the experiment; current production segmentation remains intact.

Source recordings, transcripts, case IDs and private reports stay outside Git.
No manual annotation is required for running the comparison. Machine evidence
cannot establish absolute word-for-word accuracy. Direct streaming is a separate
future phase because only an OpenRouter credential is currently available.

## Paired 3s/6s experiment outcome

The frozen eight-case dev panel produced 207 one-attempt requests. Scribe returned
nonempty text on all 46 short and 23 longer windows. GPT Transcribe returned empty
text on 15/46 short and 5/23 longer windows. Qwen had 27/46 and 12/23 technical
failures respectively. These counts describe this route/configuration, not accuracy.

Longer context did not establish a reliable quality improvement. An inspected Scribe
6s result preserved a Chinese phrase better but omitted an English negation present
in the short/full-clip outputs. Production segmentation therefore remains unchanged.
The draft/final mechanism is currently an evaluation replay, not an enabled app mode.

A separate one-request Scribe capability probe through OpenRouter returned 43
word timing records with valid ranges. This verifies availability on the tested
route, not timestamp precision. The native client now supports optional verbose
word timing metadata; malformed/partial timing arrays are rejected as a whole while
the transcript remains available. The default request and session export format
remain compatible. Next candidate architecture: acoustic overlap with time-based
alignment and a revisable tail, avoiding string-based removal of repeated examples.

## Frozen synthetic regression replay (2026-11-03)

On the 14-case authored local-TTS corpus, the replay after translation/queue changes
processed all 60 ASR requests. Qwen and GPT Transcribe matched their baseline MER
and lexical checks (14/14 and 13/14). Scribe changed from 13/14 to 12/14 lexical
checks: “银行” became “yínháng” in an English vocabulary example. A separate saved
one-request diagnostic returned “Ying Hang”. Keep this failure visible; do not infer
Chinese characters from romanization. The replay did not change the file-mode ASR
payload or segmentation, so this observation does not establish a code-caused regression.

Paired report ID: `e69f64bffcd0d172e6a884a9ab4647514b9dced1a7c0041e9c7fef1b77475f02`;
baseline ID: `7aa988e3ed965e86f31548f404c3c03a1e9ecfa7f6b93d47338de6fc37accc77`.
Script agreement is synthetic regression evidence, not real-lecture accuracy.

## Live usability and Scribe options

The user preferred Scribe's live behavior and reported Qwen as too slow. New
application preferences now default to Scribe v2; saved Qwen/GPT/custom selections
are preserved and the shortlist is unchanged. This is a usability choice, not a
new absolute accuracy ranking. Translator remains GPT-4.1 mini.

Scribe `tag_audio_events` is explicitly false. A bounded 24-request real-audio
pilot compared automatic and zh-priority recognition through Scribe/GPT. Chinese
priority improved Han presence on selected problematic clips, but word errors
remained and one Scribe wording became less plausible. The app exposes the hint
explicitly rather than treating Han output as verified Chinese recognition.
See [scribe-language-options.md](scribe-language-options.md).
