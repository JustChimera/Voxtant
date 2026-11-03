# Independent ASR regression

This suite answers: did this implementation change get closer to the same authored
speech script, lose a critical marker, invent speech or fail to process audio?
It does not establish real-world lecture accuracy or product readiness.

## Frozen corpus

Fourteen synthetic cases cover English/Mandarin, language switching, positive and
negative polarity, numbers, intentional repetitions, forced boundaries, quiet and
noisy speech, silence and noise without speech. Text and lexical constraints are
written in `Tests/Fixtures/asr-regression-v1.json` before any ASR output. Local
macOS Samantha/Tingting voices generate speech; no tested ASR or audio judge supplies
references. English and Chinese pieces are spliced with 120ms gaps. TTS pronunciation
is not human verified and differs from spontaneous speech by a single speaker.

Original synthesized audio and generated variants are frozen outside Git with
hashes, voice/rate/OS/tool provenance and explicit `synthetic_authored_source_script`
references. No human-gold or machine-silver references are rewritten. A new version
requires a new corpus directory; rerunning build reuses existing frozen audio.
No private iPhone recording or held-out real audio is involved.

The native `VoxtantEval prepare` uses production `AudioSegmenter` and `WAVEncoder`.
ASR-only replay uses production OpenRouter request/retry logic and two ASR slots.
It preserves a failed clip and continues on subsequent cases. Translation is bypassed;
normal app/session behavior is unchanged. This exercises file replay, not microphone
device capture, live queue latency or translation quality.

## Scorecard

- Main: failure-inclusive micro MER against the authored script, with English word
  and Han character units. Missing predictions remain deletions. Silence/noise
  insertions remain errors even with zero reference words in those individual cases.
- English-projection WER and Han-projection CER are diagnostic, alongside named slices.
- Lexical constraints: predeclared token sequences for polarity/numbers/vocabulary,
  exact repetition counts and absence of invented speech. Number spellings and digit
  forms may be explicit alternatives. These checks are not a general semantic judge.
- Completion, empty speech outputs, unexpected text on nonspeech, attempts, P50/P95 and known/
  unknown costs are separate. Successful-only timing never counts failures as zero.
- Common-completed-case scores use identical case IDs across all models. This subset
  is biased by API completion and is a conditional diagnostic, not the main score.

MER remains sensitive to number spelling, simplification and transcription conventions;
a passing lexical alias can coexist with a surface edit. Report these as script
agreement, never as a percentage of correctly recognized real-world speech.

## Commands

```sh
make quality-build DATASET="/absolute/private/voxtant-regression-v1"
# Paid requests to the current Scribe/GPT Transcribe pool only:
make quality-run DATASET="/absolute/private/voxtant-regression-v1" RUN_ID=baseline-v1
make quality-freeze DATASET="/absolute/private/voxtant-regression-v1" RUN_ID=baseline-v1 BASELINE=v1
# Offline: detect relevant Core/evaluator source changes without sending audio:
make quality-status DATASET="/absolute/private/voxtant-regression-v1" BASELINE=v1
# After a code change, run a NEW version and compare identical frozen inputs:
make quality-run DATASET="/absolute/private/voxtant-regression-v1" RUN_ID=change-001
make quality-compare DATASET="/absolute/private/voxtant-regression-v1" RUN_ID=change-001 BASELINE=v1
```

`quality-run` cannot join `verify`: it reads the existing OpenRouter Keychain credential
and sends paid audio requests. Before launch, the worst-case request count is checked
as prepared chunks × three models × three attempts, capped at 600. Models, audio,
selection, preparation and source are frozen per run. Terminal failures are retained;
a new run ID is needed for fresh attempts. Raw voices and results stay outside Git.

## Regression policy

A noise-event annotation such as `[static]` violates the strict empty-transcript
check but is not automatically invented spoken content. It remains visible and is
not removed from metrics after seeing model output.

The baseline is an immutable observation of the current implementation, including
known failures; it is not an accepted product-quality threshold. Hashes protect the
baseline and reports. Comparison requires the same corpus/preparation, cases, model
pool and scorer. Source changes are allowed because they are what the test compares.

A larger overall MER, new failed lexical constraint or lower completion produces a
`regression_signal`, even if another metric improves. A lost negation is not hidden
by better unrelated words. Signals are deterministic comparisons of recorded outputs,
not calibrated statistical significance. Repeat an API run before treating small
changes as stable; no invented business acceptance threshold or ready/not-ready grade
is emitted. Version the benchmark/scorer deliberately and rescore stored outputs
locally when the metric itself changes.

Reports contain fixed-case transcripts, expected scripts, violations, named slices
and prediction/scorer hashes. Source status tracks the Core/evaluator fingerprint;
UI changes and live microphone behavior need their own checks. The existing iPhone
corpus remains the external-validity stress test, with its accuracy limitations intact.

## Initial observation — baseline v1

The first fixed run completed 60 ASR requests over 20 prepared chunks, with no API
errors and all 14 cases attempted for each model. Results:

| Model | Script MER | Han spelling CER | Cases passing all lexical constraints |
|---|---:|---:|---:|
| Qwen3 ASR 1.7B | 15.8% | 2.9% | 14/14 |
| Scribe v2 | 8.4% | 8.8% | 13/14 |
| GPT Transcribe | 11.6% | 5.9% | 13/14 |

Scribe's non-passing case returned a noise-event annotation on nonspeech. GPT's
non-passing noisy mixed case lost the required Chinese negation. Several surface
edits in all models come from valid digit/word number formats; lexical alternatives
handle those formats separately. Qwen also produced extra text on mixed boundaries.
Do not read the table as calibrated real-speech accuracy or a universal model ranking.

The report fingerprint is
`7aa988e3ed965e86f31548f404c3c03a1e9ecfa7f6b93d47338de6fc37accc77`.
Frozen audio/predictions and initial scorer/native source snapshots are private.
Baseline self-comparison is unchanged for all models; the status check matches the
initial Core/evaluator code. The comparison tests also catch a newly lost negation
even when overall edit distance improves.

## Two-model cohort after Qwen removal

Qwen ASR was retired by the user on 2026-11-03. New quality runs contain Scribe and
GPT Transcribe only and use matching model-based run suffixes. The driver fingerprint
also changes with this harness update; old three-model baseline v1 and raw reports
are immutable historical results. Do not silently overwrite v1 or compare a new
two-model run against its three-model cohort. A newly measured run must be frozen
under a new baseline name (for example `v2-scribe-gpt`) before future paired checks.
No network replay or new baseline was created as part of removing the model.
