# Desktop recording library and costs — 2026-11-03

New recordings use `~/Desktop/Voxtant Recordings/yyyy-MM-dd/HH-mm-ss_ID/`.
The root is initialized by the normal app; each local-calendar date is created
when recording begins. Session IDs prevent collisions within the same second.
The user explicitly selected **new recordings only**. Legacy sessions and their
paths remain untouched. Keychain/bundle identifiers and session schema v2 remain.

Each session has original `recording.caf` (or copied imported source),
`transcript.txt`, `translation.txt`, compact `metadata.json` schema v1, detailed
`session.json` schema v2, and `chunks/*.wav`. Files update atomically. Metadata
freezes model IDs, language rules, optional ASR hint, microphone name, audio
threshold, segmentation/WAV/gate parameters, timestamps, duration, status and cost.
Stop continues to cancel requests permanently while retaining captured audio.

## Cost meaning

`cost.reportedUSD` sums available API-reported attempt amounts exactly once,
including reported retry costs. It does not multiply local durations by advertised
prices. `cost.isComplete=false` means at least one needed amount is unknown,
pending or cancelled; unknown costs are never zero-filled into a complete bill.
Local noise filtering and Chinese preservation bypass incur no API translation
charge. The widget shows a lower bound with “от” when only part is known and
unknown symbols when nothing is reported. Original attempt records remain in the
full session. A cancelled remote operation may still be billed by the provider.

`cost.approximateRUB` is a reference conversion using `cost.exchangeRate`:
`rublesPerUSD`, `effectiveDate`, `fetchedAt`, `source`. The source is the official
CBR XML feed over HTTPS. Refresh is background-only with a 6-second request limit
and 6-hour local cache. A previous dated cache remains usable offline. Without a
valid cache, RUB stays unavailable while USD works. The rate freezes per session;
if startup had no rate, the first successful response supplies it. This is not a
bank/card/market execution rate. No secret, audio or transcript goes to CBR.

## Panel and device handling

The panel supports native edge resizing plus a lower-right handle, minimum
300×300, full-frame persistence and display clamping. The original regular native glass fill/transparency was restored at the user’s
request; the resizable frame and cost footer remain.
Settings expose the library path. Original audio/transcription quality is not
changed by these UI/storage changes.

Microphone inventory includes CoreAudio inputs and AVFoundation-discoverable
inputs with matching UIDs, retaining suspended inputs rather than filtering every
DeviceIsAlive=0 entry. A retained discovery session, HAL device notifications and
AV connection notifications refresh while idle; the picker also refreshes before
opening. Stable UID resolution and startup error handling remain. At inspection,
both HAL and AVFoundation exposed only the MacBook microphone, so actual iPhone
capture could not be verified. The app cannot create a Continuity endpoint absent
from macOS. Check iPhone Continuity Camera, same Apple Account/proximity/connectivity,
or trusted USB; the iPhone must appear under macOS Sound → Input.

## Verification

Core tests cover nominal-aware USD XML parsing, malformed rates, no double billing,
partial/cancelled costs, local bypass and calendar grouping/unique session paths.
UI smoke exercises real file writes under an injected temporary library, metadata,
USD/RUB footer, native resizing/full-frame restoration and existing permanent Stop.
A public rate probe successfully parsed CBR 03.11.2026: 80.9734 RUB/USD; this value
is evidence of the probe, never a hardcoded fallback. No paid ASR/translation run
or microphone capture is required by this change. Actual iPhone connectivity and
bank-side final billing remain outside these local checks.

References: [CBR XML feed documentation](https://www.cbr.ru/development/SXML/),
[Apple Continuity Camera](https://support.apple.com/en-gb/102546).
