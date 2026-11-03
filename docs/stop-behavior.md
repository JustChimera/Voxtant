# Stop cancels processing — 2026-11-03

The user requires Stop to end the current recording and all remaining processing.
The previous implementation stopped capture but drained ASR/translation/recovery,
keeping controls busy while waiting for replies. This behavior is superseded.

Stop now suspends scheduling, retires the processing generation, cancels ASR and
translation tasks, releases their UI worker ownership and clears provisional text.
It awaits only the capture's serial local disk flush. Flush callbacks retain their
saved WAV entries as cancelled without enqueueing another API request. Completed
translations and source audio remain. Abandoned cells use the existing optional
`translationMode=cancelled-by-user`, empty error and terminal status; schema stays
v2. They are excluded from the completed-translation count. No new cancelled-error
rows appear in the widget, and the status becomes “Остановлено”.

All async success/error/partial/cleanup paths check their generation before
mutating state. A stopped request cannot fail, clear or decrement work in a newer
processing generation, even when indices are reused. Capture callbacks also check
session identity. Explicit manual retries reset scheduling; abandoned cells are
not automatically retried. SSE transport cancellation explicitly cancels the
underlying URLSessionTask, including a server that sends headers/partial text and
then goes silent. Already-sent remote work cannot be undone or guaranteed refunded.

A functional UI smoke fixture injects an ephemeral URLProtocol session: two ASR
requests never answer, a translation emits provisional SSE then never completes,
and another cell remains queued. Stop must return in under 0.5 seconds without
receiving a response, clear busy/pending, cancel all three held transport requests,
preserve final text/WAV, discard the draft, and neutral-mark four abandoned cells
in export. Immediate new work reuses an index and must complete unaffected by old
cancellation callbacks. No microphone, Keychain or external API is used.

Run `make ui-smoke` for this functional regression and existing widget checks.
Run `make verify` for Core/Python checks, lint and build. Acoustic/recognition
quality is not changed or established by this cancellation test. Actual local
disk flush time depends on the filesystem; Stop never awaits model inference.
