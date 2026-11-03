# Translation selection — 2026-11-03

## Decision

Use **`openai/gpt-4.1-mini`** through OpenRouter as the recommended default.
Keep **`qwen/qwen3-next-80b-a3b-instruct`** as the measured faster alternative,
selectable by entering its ID in settings. The current ASR choices are Scribe v2 and GPT Transcribe; Qwen ASR was retired after the historical comparisons below. ASR and translation are separate model selections.
Existing saved Flash Lite migrates to the new translator; other custom IDs persist.

The general suite tied the finalists after prompt hardening, but an additional
Mandarin grammar case separated them: Qwen Next twice rendered “measure word”
as “количественное слово”, while GPT twice used “счётное слово”. The input context
explicitly identifies a Mandarin grammar lesson. This is a terminology distinction,
not a claim of universal model superiority. Given the current priority on quality,
GPT is the default even though Qwen has lower median latency.

## Method

Only independent authored text was sent, not private recordings, ASR outputs or
machine-silver references. `translation-v1.json` contains 16 cases: negation,
numbers, repetitions, fragments, context, literal spoken instructions, mixed Han
preservation and language settings. The terminology supplement has four cases.
Fixtures and constraints are frozen before responses; failed examples are retained.
No scorer adjustment was made to forgive the terminology failure.

Each phase uses two repetitions, rotating model order, sequential native URLSession
requests through the production client. General counts below exclude the one local
pure-Chinese preservation case per repetition/model. Checks are lexical/structural
constraints, **not calibrated semantic accuracy**. Responses were inspected as well.
The small corpus and one route/time window do not establish real-lecture accuracy.

## Initial six-model screen

Original prompt, non-streaming, ordinary routing; 30 remote examples per model.
Failures count against passed/planned; timing is over successful responses only.

| Model ID | Constraints passed | API/guard failures | Full response P50 / P95, seconds |
|---|---:|---:|---:|
| `google/gemini-2.5-flash-lite` | 25/30 | 2 | 1.721 / 3.460 |
| `qwen/qwen3-30b-a3b-instruct-2507` | 26/30 | 0 | 1.408 / 2.596 |
| `qwen/qwen3-next-80b-a3b-instruct` | 28/30 | 0 | 0.791 / 1.068 |
| `mistralai/mistral-small-3.2-24b-instruct` | 27/30 | 1 | 1.060 / 3.257 |
| `anthropic/claude-haiku-4.5` | 26/30 | 0 | 1.242 / 2.324 |
| `openai/gpt-4.1-mini` | 28/30 | 0 | 1.121 / 1.754 |

All six mishandled a spoken instruction override: most executed the quoted sentence
instead of translating it, and Haiku refused/commented. This was a shared prompt
failure, not evidence that swapping models alone solves it.

## Hardened finalists

The prompt now treats `context` and `current_utterance` as JSON speech data and
requires literal translation of commands/questions. Both finalists translate the
instruction example correctly. The phase also enables SSE and latency routing,
so improvements cannot be causally attributed to streaming alone.

| Model | General constraints | Full response P50 / P95, s | First safe text P50, s |
|---|---:|---:|---:|
| Qwen Next | 30/30 | 0.694 / 1.618 | 0.623 |
| GPT-4.1 mini | 30/30 | 0.875 / 1.288 | 0.756 |

| Model | Terminology constraints | Full response P50 / P95, s | First safe text P50, s |
|---|---:|---:|---:|
| Qwen Next | 6/8 | 0.629 / 1.940 | 0.508 |
| GPT-4.1 mini | 8/8 | 0.869 / 1.201 | 0.711 |

No API failures occurred in either finalist phase. General + terminology totals
are GPT **38/38**, Qwen **36/38** remote examples. These totals are checks on short
authored cases, not “100% translation accuracy”. The initial screen was used to
choose finalists and improve the prompt, so the general replay is a regression
check rather than unseen holdout evidence. Terminology is a small independent
supplement, not an exhaustive quality benchmark.

## What is faster

Relative to the old Gemini Lite profile, the chosen GPT profile reduced general
median full translation from **1.721 to 0.875 seconds (~1.97×)**; first safe text is
**0.756 seconds (~2.28× earlier than the old complete response)**. Qwen's optional
profile is 0.694 seconds full (~2.48×) and 0.623 seconds first (~2.76×).

These are **translation-stage** comparisons after a transcript exists. The widget
shows provisional text dimmed and commits/exports only after final validation.
SSE handles fragmented UTF-8, metadata, keepalives, stream errors and truncation;
Chinese placeholders are restored atomically and never exposed as raw tokens.

Microphone audio still accumulates in 1.2–2.8 second WAV chunks before ASR.
An old slow session had median ASR queue wait of 19.629 seconds despite median ASR
service of 1.113 seconds. To reduce this head-of-line effect, new live audio gets
one 8-second ASR attempt (the initial 4-second limit was reverted after a live timeout regression); eligible temporary failures move to saved-WAV recovery
with two regular attempts. Fresh audio has priority; while live, recovery uses at
most one spare slot. File evaluation retains its original retry policy. Explicit
rate limits/Retry-After and authentication/quota failures are not bypassed.

An explicit Stop now cancels queued/in-flight work instead of draining it; only
local audio flush is awaited (see [stop-behavior.md](stop-behavior.md)).

The queue policy is unit-tested, **not yet measured in a new paced end-to-end
microphone run**. No whole-pipeline speedup factor is claimed. Native continuous
streaming ASR is a separate integration requiring an available direct provider
credential; current OpenRouter WAV replay does not establish that capability.
Cold/provider latency outliers remain possible (a finalist Qwen response took 4.11s).

## Reproduction and provenance

```sh
make translation-eval OUTPUT=/absolute/private/translation-screen
make translation-eval OUTPUT=/absolute/private/translation-finalists \
  EVAL_ARGS="--models qwen/qwen3-next-80b-a3b-instruct,openai/gpt-4.1-mini --streaming --latency-routing"
make translation-eval OUTPUT=/absolute/private/translation-terminology \
  EVAL_ARGS="--models qwen/qwen3-next-80b-a3b-instruct,openai/gpt-4.1-mini --suite terminology --streaming --latency-routing"
make translation-report OUTPUT=/absolute/private/translation-finalists
```

Network runs are explicit paid actions and never part of `verify`. Credentials
stay in Keychain/process stdin. Frozen config, fixture/source/runner hashes, raw
responses, attempts, errors and reported costs remain in the private output folder.
Private run names: `baseline`, `optimized-finalists`, `terminology-finalists` under
`voxtant-translation-v1`. Public source contains fixtures/scorer only. Changing
source after a run does not overwrite its frozen provenance; choose a new output
folder for a new run.

Protocol references: [OpenRouter streaming](https://openrouter.ai/docs/api_reference/streaming),
[provider selection](https://openrouter.ai/docs/guides/routing/provider-selection),
[latency guidance](https://openrouter.ai/docs/guides/best-practices/latency-and-performance).
