# Live ASR timeout regression (2026-11-03)

Subsequent Stop behavior: an explicit Stop now cancels queued/in-flight work
instead of draining it. The source-based retry budget below applies during live
processing and explicit manual retries. See [stop-behavior.md](stop-behavior.md).

## Evidence and correction

A real microphone session had nine consecutive initial Qwen requests cancelled
at approximately 4.15–4.34 seconds by our new 4-second client timeout. The first
utterance was available only about 42 seconds after it was queued, including
background waiting and recovery. Later short sessions returned Qwen responses
in roughly 0.75–2.46 seconds; the route is variable. This is not a calibrated
provider reliability benchmark, and it does not prove all cancelled calls would
have succeeded under a larger deadline.

A short deadline cannot accelerate provider inference. The fresh microphone
attempt is restored to 8 seconds, retaining one attempt before background recovery
and the priority for new audio. Recovery has at most two regular attempts. Total
attempt count remains three. The session source, rather than the current capture
state, now determines this policy: pressing Stop must not give queued microphone
fragments a new three-attempt file policy. File replay is unchanged. Retry-After,
rate limits, authentication failures and audio preservation retain their behavior.

Tests cover fresh priority, idle-slot recovery, bounded attempt count, stable
microphone policy after Stop, unchanged file policy and explicit rate limits.
These checks establish scheduling/configuration behavior, not network speed or
recognition accuracy. No improvement in ASR word accuracy is claimed from this fix.
A new live network run is required to measure the actual latency impact.

## Repeated Chinese filler

The raw ASR outputs already contained “嗯。”; GPT translation was bypassed under
the configured exact Chinese preservation rule. A malformed Russian sentence was
also present in raw ASR. The translator did not originate either issue.

Local Apple SoundAnalysis (.version1, 1-second windows, 50% overlap) was used only
as a diagnostic on three saved WAVs, with no external upload. Mean speech scores:
0.654 on the initial greeting, 0.0087 on one “嗯” fragment, and 0.317 on a later
greeting. Scores are classifier outputs, not ground truth or calibrated probabilities.
The repeated-filler windows also had much flatter/lower energy than the greeting.
This supports investigating background noise passing the energy-only VAD; it does
not establish exactly what was spoken in every fragment.

No literal “嗯” blacklist, character reconstruction, or transcript deduplication
was added. Short genuine Chinese interjections and repeated examples must survive.
A stronger speech/noise gate needs its own acoustic regression, especially on quiet
Chinese, before replacing the current energy detector.
