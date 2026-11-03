# Conservative local speech gate — 2026-11-03

## Problem and behavior

The user confirmed that repeated “嗯” occurred during pauses/background noise.
Qwen returned these characters before translation. The configured exact Chinese
preservation rule then correctly retained them. A transcript blacklist would
also delete genuine Chinese interjections and repeated teaching examples.

Energy VAD still creates 1.2–2.8s non-overlapping chunks. Before production/native
replay ASR, saved WAVs are now checked locally with Apple SoundAnalysis version1.
Only a fully analyzed clip of at least 1s whose **maximum** speech score is below
0.05 is vetoed. One speech/uncertain window keeps the whole clip. Short clips,
unsupported input, classifier errors, missing results and incomplete coverage pass
through to ASR. Classifier scores are not calibrated probabilities.

Analysis runs outside MainActor. A temporary in-memory buffer is padded with
silence to cover final real samples in complete 1s windows (50% overlap). Saved
WAV bytes, original CAF, audio boundaries and payload normalization are unchanged.
A rejected clip remains in session.json as complete/empty with zero API cost and
`translationMode=local-nonspeech-v1`. Per-clip reason, score, window count and local
duration are recorded in existing session notes. No export schema change is needed.
Direct OpenRouterClient callers opt in with `filterNonSpeech: true`; the app and
native evaluation enable it. No external dependency, permission or account is added.

## Local acoustic evidence

A 44-case panel combined authored synthetic scripts (whole files and production
chunks), three live speech controls and seven user-confirmed noise/filler windows.
It preserved **33/33 speech cases** and rejected **10/11 noise cases**. The remaining
noise control was a 0.2s tail, intentionally passed by the short-input rule.
Median local analysis across this panel was approximately **55 ms**; cold inference
can be slower. Whole files and their chunks are correlated, not 44 independent
speakers. This is an acoustic regression panel, not real-lecture accuracy.

An additional independently authored 12-case edge panel preserved **11/11 speech
cases**, including a genuine synthesized “嗯”, repetitions, a very quiet Chinese
negative sentence, and English/Chinese words at the beginning/end of background
noise. Its low-frequency noise control was rejected (1/1). Local TTS audio was
validated as nonempty before acceptance. Two early sandbox TTS attempts produced
zero frames and were marked invalid; their reports remain preserved for audit.
No detector threshold was changed to forgive those invalid fixtures.

Private local outputs: `voxtant-speech-gate-v1/acoustic-v1` and
`voxtant-speech-gate-edge-v3/acoustic-v1`. Their manifests preserve input identities
and SHA256 values. Final acoustic reruns also freeze fixture bytes, runner SHA and
macOS version. These small, partly synthetic controls do not establish safety for
all accents, whispering, music, classroom noise or isolated nasal sounds.

## Native ASR replay

The unchanged frozen 14-case/20-chunk corpus was replayed with all three selected
ASR models, translation disabled. Gate-vetoed chunks made no network request.

| Model | Script MER | Han CER | Lexical cases | Baseline comparison |
|---|---:|---:|---:|---|
| Qwen3 ASR | 15.8% | 2.9% | 14/14 | unchanged |
| Scribe v2 | 7.4% | 8.8% | 14/14 | noise constraint fixed; surface MER lower |
| GPT Transcribe | 11.6% | 5.9% | 13/14 | unchanged |

All cases completed; no new lexical failures. The GPT noisy-negation failure is
still present. Scribe's earlier Han/pinyin variation remains a known limitation;
this replay does not establish a recognition fix for that issue. Fewer noise
requests do not imply faster or more accurate model inference on speech.

Baseline report: `7aa988e3ed965e86f31548f404c3c03a1e9ecfa7f6b93d47338de6fc37accc77`.
Gate replay report: `985c5b11db74ab38fe46d281b26734e1bb42b86b680b71d4f02de0f44830a6ac`.
Run ID: `speech-gate-v1`. Same corpus/scorer, failure-inclusive paired comparison.
After that replay, only acoustic CLI fixture validation/provenance and evaluator
note restoration were hardened; production gate/model requests stayed unchanged.
No new private live voice was uploaded during this task. Human-verified accuracy,
long-session stability and new end-to-end latency remain unproven.

## Reproduction

```sh
make speech-gate-eval DATASET=/absolute/private/panel OUTPUT=/new/private/output
make quality-run DATASET=/absolute/private/frozen-regression RUN_ID=speech-gate-v1
make quality-compare DATASET=/absolute/private/frozen-regression RUN_ID=speech-gate-v1
```

The acoustic manifest is `speech-gate-cases.json` with cases containing `id`,
`audio` (relative path), and `expectedSpeech`. Acoustic evaluation uses no Keychain,
network or microphone. ASR replay is a separate explicit paid action on synthetic
fixtures. The local gate does not guarantee elimination of all background text.

References: [Apple built-in sound classification](https://developer.apple.com/videos/play/wwdc2021/10036/),
[window duration](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest/windowduration).
