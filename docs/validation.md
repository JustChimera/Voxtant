# Validation workflow

The corpus and all speech/transcripts/references are private local data outside Git. The repo contains tooling and synthetic tests only. No infrastructure or external Python packages are required. Extraction uses the already installed ffmpeg/ffprobe; native chunk preparation needs a macOS GUI login with access to the normal system audio decoder. No microphone is used.

## First dataset

`voxtant-validation-v1` selects one deterministic, nominal 18-second window per remaining Voice Memos recording, including quiet/short examples. The three previously inspected pilot recordings are excluded using the prior private pilot manifest passed as `PILOT_MANIFEST`. No recording filenames or source IDs are embedded in the tooling. Without a pilot manifest, all fully downloaded recordings are eligible for deterministic selection. Selection uses a fixed seed and source ID hash, not model output or perceived clarity. AAC packet boundaries can shift the nominal excerpt boundary by one frame.

The manifest fingerprints audio bytes, sample offsets, source IDs, eligibility and date groups. Two previously unseen recording days are reserved before inference. The first corpus contains 34 clips (555.4 seconds): 25 dev and 9 holdout. One holdout recording below one second is retained as an edge case but excluded from model runs. This is a date-separated classroom corpus, not a speaker-independent sample of general conversations.

The original Voice Memos files are read-only inputs. Ordinary AAC tracks are copied into private sample M4As without recompression; spatial tracks are excluded. Original files and Keychain entries are never modified. `VoxtantEval prepare` decodes the samples and uses the production `AudioSegmenter`/`WAVEncoder` (threshold -48 dBFS, target 1.2 s, max 2.8 s, 120 ms pre-roll, normalization max gain 8x). Prepared chunks are immutable; choose a new dataset directory for a changed preparation. The manifest ID identifies the sampled corpus; `preparedHash` identifies exact chunk bytes/boundaries.

## Commands

Use an absolute private directory for DATASET. This directory must not be tracked by Git.

```sh
make eval-test
make eval-dataset DATASET="/absolute/private/voxtant-validation-v1" PILOT_MANIFEST="/absolute/private/previous-pilot/manifest.json"
make eval-prepare DATASET="/absolute/private/voxtant-validation-v1"
# Paid OpenRouter requests using the existing Keychain credential:
make eval-run DATASET="/absolute/private/voxtant-validation-v1" EVAL_ARGS="--run-id baseline-qwen-v1"
make eval-run DATASET="/absolute/private/voxtant-validation-v1" ASR_MODEL=google/gemini-2.5-flash EVAL_ARGS="--run-id comparison-gemini-v1 --limit 8"
make eval-report DATASET="/absolute/private/voxtant-validation-v1"
```

`eval-run` builds the evaluator; defaults are Scribe v2 ASR and GPT-4.1 mini translation, matching the selected application defaults. The historical Flash default was a workaround for Flash Lite upstream shared-pool 429s; it is no longer the selected translator. See [translation-selection.md](translation-selection.md). Use optional `--asr-language-hint zh` for an explicit mixed-mode language-priority experiment; the ordinary single-source language takes precedence. A stable date-diverse panel selected before model output is used by `--limit`; `--case-ids` can freeze an explicit panel.

The key is read via the existing macOS Keychain service and passed to the Swift runner on stdin, never as an argument, environment value, output or disk file. Two ASR and two translation slots mirror the app. Each request uses production retries. Four terminal failures within a clip stop further scheduling and the rest of the run; queued/unattempted cases remain incomplete. Resume with the exact run ID/configuration to finish interrupted jobs; terminal failures remain recorded and need a new run for a new attempt. Changed audio, selection, settings or source fingerprint rejects resume.

Each run stores model/settings, dataset/preparation/source hashes, Git HEAD plus dirty state, executable hash, Swift/Python versions, original attempt diagnostics, exact causal contexts and output. ASR models may have different causal predicted context, as in the app; this is an end-to-end pipeline comparison, not a context-controlled acoustic benchmark. `latencySeconds` is intentionally absent. Stage times and batch wall time include network/retry effects and do not measure live microphone latency. Stage quantiles are conditional on successful results; failures remain separate instead of being counted as zero. Each invocation is appended to `launches.jsonl`, and the original provenance snapshot is retained.

## Automatic validation (default, no manual moderation)

```sh
make eval-auto DATASET="/absolute/private/voxtant-validation-v1"
make eval-auto-report DATASET="/absolute/private/voxtant-validation-v1"
# A changed protocol uses a new immutable version:
make eval-auto DATASET="/absolute/private/voxtant-validation-v1" EVAL_ARGS="--version v2"
```

The authorized model allowlist is fixed to `openai/whisper-large-v3`, `elevenlabs/scribe-v2` and `openai/gpt-audio`. New models cannot be passed through CLI arguments. Keychain access and request privacy follow the same contract as other evaluation tools; network calls are explicit, bounded to 110 attempts per invocation and never part of `verify`.

Each teacher receives only a whole dev audio clip, not student Qwen/Gemini outputs or human references. Whole-clip audio is converted to mono 16 kHz PCM16 WAV and peak-normalized to 0.8 with gain capped at 8x. This offline preprocessing and future context differ from the live chunked student pipeline. WAV is required because GPT Audio rejects M4A input. The raw outputs, request/audio hashes, model, prompt hashes, providers, costs and attempts are preserved privately.

Three distinct model lineages transcribe independently. Whisper and GPT Audio share a vendor; this is diversity, not a claim of statistically independent errors. Runaway repetitions, truncated responses, refusal/unclear markers and request failures are excluded from supporting evidence; ordinary repetitions and other languages are retained. Explicit non-speech event labels such as `[music]` are removed only from comparison text; raw text is retained.

Frozen v1 agreement filtering accepts a pair of different lineages within normalized token distance 0.08, provided a third valid output is not farther than 0.25. These are protocol heuristics, not calibrated confidence or product acceptance thresholds. Otherwise GPT Audio checks anonymous candidate transcripts against the audio, without seeing student outputs. It can only select an existing candidate or abstain; acceptance still requires separate-lineage support within distance 0.18 and no unresolved audio. Its second pass is not counted as a fourth independent model. An unsupported solo judgement never becomes a reference.

The output is `machine_silver`, always `humanReviewed: false`, stored under `auto-references/<version>/reference.json`. A reference fingerprint locks the result. Exact source/normalizer snapshots preserve provenance; changes to the decision policy or normalization require a new version, while a reporting-only change can reuse frozen labels without paid requests. Uncertain cases are quarantined and remain part of operational stress tests; no human action is required to keep evaluation running. They are not silently treated as correct labels or removed from reliability reporting. `references.json` (optional human gold) is never written by this tool.

The automatic report uses `silverReferenceDistance`, a selective MER/WER/CER distance proxy, while real human-verified accuracy remains unknown. Coverage and quarantine counts are mandatory. Grades are evidence categories, not probabilities. For future models in a teacher/judge lineage, dependent references are excluded to prevent self-evaluation. Comparisons use the same accepted reference IDs planned for all student groups; unplanned cases are not counted as failures. Failed/partial predictions on planned cases remain penalized. Recovery runs are grouped only when source/preparation/settings/models match, choosing the most complete available result without looking at reference agreement. Initial errors remain in run history.

After model/prompt changes run the fixed dev corpus, then `eval-auto-report` against the unchanged machine references. A new teacher/protocol version creates a new fingerprint rather than rewriting the benchmark. Successful evidence can be reused by exact request hash; failed evidence may be retried only on an explicit new run/version, with its previous record retained. Holdout is never sent through automatic-reference generation during development. Ordinary `eval-report` includes the latest automatic report without requesting manual moderation.

## Human references (optional)

Open the generated `review.html` locally. Play the audio before revealing model candidates. Write verbatim audible text: English words and Mandarin Han characters, preserving repetitions and unfinished words; do not correct grammar or infer unheard words. If it is unclear, leave it unreviewed and note `unclear`; report coverage alongside scores. Explicitly confirm true silence. A reviewer identity and an explicit reviewed checkbox are mandatory. Model agreement is only a triage signal.

Download `references-reviewed.json`, then import it:

```sh
python3 scripts/validation.py import-references --dataset "/absolute/private/voxtant-validation-v1" --file "/absolute/private/references-reviewed.json"
make eval-report DATASET="/absolute/private/voxtant-validation-v1"
```

The importer validates corpus and audio hashes, backs up previous references, and accepts only explicit human review metadata as scoreable. This is a workflow provenance declaration, not cryptographic authentication of a reviewer. Local browser drafts are convenient; downloaded JSON is the durable handoff.

## Metrics and comparison

Primary ASR metric is micro-averaged mixed error rate (MER): English word units and Chinese Han scalar units in their original sequence, with edit substitutions/deletions/insertions divided by reference units. This mixed-unit convention follows code-switching ASR evaluation; see [Interspeech 2024](https://www.isca-archive.org/interspeech_2024/hussein24_interspeech.pdf). [NVIDIA's evaluation guide](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/public/asr/asr-basics-customization-riva.html) also requires human-verified reference transcripts for WER.

Normalization v1 uses NFKC, case folding, normalized apostrophes and punctuation separators. No repeat removal, Chinese reconstruction, simplified/traditional conversion, number spelling conversion, stemming or semantic correction occurs. Numeric `500` and `五百` remain different. English-projection WER and Han-projection CER are diagnostic: they omit cross-language ordering, which MER retains. Other scripts remain word units in MER and are outside these two projections.

Only reviewed references count. Confirmed-silent references contribute hallucinated insertions; zero reference denominator remains undefined. A missing/failed prediction against a human reference counts deletions instead of being dropped. Corpus errors are divided by the corpus reference count; clip percentages are not averaged. Error rate can exceed 100% due to insertions.

`leaderboard.json` shows reference coverage and separate service timing/error/cost metrics. Pairwise accuracy comparison uses only identical reviewed case IDs; when `comparison-plan.json` is present, cross-model scores are restricted to its fixed panel, excluding adaptively selected failure-recovery examples. Human tags also produce named score slices; a large run must not be ranked against a small run's accuracy without this paired intersection. No production acceptance threshold is invented; the user's accuracy/latency priority and acceptance limits must be agreed before final selection.

Accuracy remains null until references are reviewed. Model disagreement, residual Latin text, empty hypotheses, unusually long repetitions/output rate, other-source-language hints and Han preservation are review signals, not measured accuracy. These flags never remove repetitions or exclude hard samples automatically. Add human language/noise/cutoff tags in the review page to assess slices after reference review. The corpus includes device-test recordings that may be outside the expected English/Mandarin classroom domain. Translation Han preservation is relative to the ASR transcript, not ground truth. Meaning, omissions and native Chinese accuracy need human checks. Translation quality is not inferred from ASR MER.

Scores are versioned by prediction, reference and scorer hashes under each run's `scores/`; the reference subset is snapshotted alongside them. `metrics.json` is the latest view. Run the same dev corpus after any model/prompt/segmenter change and review paired regressions. Preserve older outcomes, including failures and unknown costs.

## Holdout

Dev reports/review pages exclude holdout outputs. Do not inspect or optimize against the holdout during development. Freeze configuration and normalization, freeze the chosen reference protocol (human gold if available, otherwise explicitly labelled machine silver), then explicitly open it for one final assessment:

```sh
make eval-run DATASET="/absolute/private/voxtant-validation-v1" EVAL_ARGS="--run-id final-holdout-v1 --split holdout --unseal-holdout"
python3 scripts/validation.py report --dataset "/absolute/private/voxtant-validation-v1" --unseal-holdout
```

The explicit flag prevents accidental API use/inspection; it is not an access-control boundary. If the holdout influences tuning, create a fresh held-out group for the next final assessment. Long-session reliability and true microphone latency still need separate live tests.

## Expanded ASR candidates (OpenRouter file replay)

```sh
make eval-candidates DATASET="/absolute/private/voxtant-validation-v1"
make eval-candidates-report DATASET="/absolute/private/voxtant-validation-v1"
```

This explicit paid comparison excludes Gemini and isolates recognition from translation.
The selected default pool is Scribe v2 and GPT Transcribe; Qwen ASR is retired from new requests. Historical expanded comparison results below remain available.
Use `EVAL_ARGS="--expanded --run-id expanded-asr-v2"` for the historical seven-model pool:
Qwen3 ASR 1.7B, Deepgram Nova-3, Scribe v2, GPT Transcribe,
GPT-4o Transcribe, MAI Transcribe 2 and Whisper Large V3 Turbo. All use the existing
OpenRouter Keychain credential. No new credential is created or changed.
Deepgram explicitly requests `language=multi`; other models use automatic language
identification. Provider-specific language hints are not assumed to pass through.
Public catalog entries are snapshotted before sending audio.

Each model receives all eligible dev clips as whole normalized WAV files, then the
previously frozen comparison panel as exact production WAV chunks. No model gets
another model's answers or preceding transcript prompts. Whole and chunked conditions
have different acoustic context and separate scores; these are not native streaming
implementations. The ASR-only tool does not change application models or the existing
end-to-end validation runner.

Two workers interleave models on identical inputs, with a 15-second HTTP timeout,
at most two attempts per request and 1100 attempts per invocation. Retry-After above
five seconds stops that request. Authentication/balance errors stop new calls;
400/403/404 disable the affected model. Empty successful answers are counted separately
from nonempty answers and HTTP failures; emptiness alone does not prove a missed utterance.
The Python urllib transport does not configure connection reuse and differs from the
production URLSession transport, so absolute timings must not be projected onto the app. Failures and disabled/unattempted requests
remain visible; successful timing quantiles exclude failures. HTTP timing is not
first-partial latency or microphone-to-translation latency. Production retry settings
remain unchanged.

Private `candidate-runs/<run-id>` contains frozen configuration, exact audio/request
hashes, source/normalizer/reference snapshots, catalog, raw responses, attempts,
reported/unknown costs, and JSON/Markdown reports. Resume requires identical source,
inputs and configuration; it reuses all terminal results, including failures. Use a
new run ID for another attempt. Reports read a frozen machine-reference snapshot,
exclude references dependent on the candidate's lineage and leave real accuracy null.
Candidate-specific eligible reference sets can differ: compare proxy scores only on
identical scoredCaseIDs. This tool never regenerates teachers or opens holdout data.

The streaming queue is tracked explicitly: Speechmatics Realtime `cmn_en`, Deepgram
Nova-3 WebSocket, OpenAI `gpt-live-transcribe`, Scribe v2 Realtime and Alibaba
Qwen3-ASR-Flash-Realtime. They require a separate direct API/credential integration.
OpenRouter file results must not be presented as results for these streaming versions.

Protocol sources: [OpenRouter STT](https://openrouter.ai/docs/guides/overview/multimodal/stt),
[Deepgram multilingual code switching](https://developers.deepgram.com/docs/multilingual-code-switching).

## Paired context experiment

```sh
make eval-context DATASET="/absolute/private/voxtant-validation-v1"
make eval-context-report DATASET="/absolute/private/voxtant-validation-v1"
```

The selected three-model pool is frozen in `candidate_validation.PRIMARY_MODELS`.
See [asr-selection.md](asr-selection.md) for the decision and unresolved quality limits.
The fixed eight-case dev comparison panel is decoded once per clip with ffmpeg into
mono 16 kHz float PCM. Non-overlapping 3s and 6s windows each cover the entire clip;
a tail shorter than 250 ms is joined to its preceding window. Every WAV is independently
peak-normalized to 0.8 with maximum gain 8x. No energy VAD or word deduplication is used.
This differs from the production energy VAD; results must not be attributed only to
context length by comparing them with historical production chunks.

The 3s condition is a concurrent control with identical decoding and normalization.
For draft/final replay, reuse the first 3s response within each 6s block as a provisional
line and replace that block with its 6s response. Final blocks never overlap; real
repetitions are retained. Replay events describe when audio becomes available, not
measured real-time playback, queue delay or completed translation latency. This is a
bounded architecture experiment, not a production streaming integration.

At most 240 HTTP attempts per invocation, two workers, one attempt per request and a
15s timeout. Paid requests use only the authorized OpenRouter models and existing
Keychain credential. No new provider, teacher, holdout access or translator is involved.
Private `context-runs/<run-id>` freezes WAV hashes, protocol/source/remote/normalizer
snapshots, references and responses. Resume rejects any input or protocol changes.
Failures, empty responses and quarantined examples remain visible. Machine references
retain lineage exclusions; confirmed human accuracy stays unknown.

### Word-timing capability

`OpenRouterClient.transcribe(..., wordTimestamps: true)` opts into `verbose_json`
and `timestamp_granularities: ["word"]`. `APIResult.words` contains optional model
estimates. A separate Scribe capability probe returned 43 range-valid timing rows.
Neither schema validation nor provider timing proves exact word alignment. Missing,
out-of-order, non-finite or otherwise malformed timing metadata returns nil as a
whole; the original transcript is retained. Real repeated words and punctuation
are not deduplicated. Timing metadata is not yet used to revise production segments
or added to the existing session export schema.

API contract: [OpenRouter verbose transcripts](https://openrouter.ai/docs/guides/overview/multimodal/stt#verbose-transcripts-timestamps-and-speakers).

## Independent authored-script regression

`make quality-build`, `quality-run`, `quality-freeze`, `quality-compare` and
`quality-status` provide a separate independent-script scorecard for the selected
three models. It exercises the native segmenter/ASR pipeline on frozen local-TTS
cases and detects changes without using a candidate as its own reference.
See [quality-regression.md](quality-regression.md). Synthetic script agreement,
real-recording machine-silver distances and human accuracy are separate metrics.
