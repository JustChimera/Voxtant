# Microphone startup: stale CoreAudio ID (2026-11-03)

Observed symptom: the widget remained idle after Start with NSOSStatusErrorDomain
-10851 (`kAudioUnitErr_InvalidPropertyValue`). A narrow system log for the Voxtant
process showed `caller requesting device change ... to 83`, followed by
`AudioDeviceGetPropertyInfo: no device with given ID` and `device is not useable`.
The user-visible numeric error hid the actual missing-device condition.

The UI cached a numeric AudioDeviceID when listing microphones. That ID can become
invalid before Start, including while microphone permission is pending or CoreAudio
rebuilds its aggregate devices. Startup passed the cached ID directly to setDeviceID.

Microphones now retain their CoreAudio device UID. Refresh and startup resolve the
same UID in a fresh inventory of alive input devices. The capture layer repeats this
after constructing the engine input node. Missing devices produce an actionable
message, with no switch to another device that happens to reuse the old numeric ID.
No global input/output preferences, audio services, permissions or model settings
were reset. Mid-recording disconnect handling still preserves audio and stops.

Validation: build passed; 27/27 UI checks passed, including a changed ID for the
same UID, ID reuse by a different UID, and equal display names with different UIDs.
An explicit local hardware check captured two separate one-second recordings,
each 48,000 frames, 48 kHz, mono. No API, credentials or transcription was used.
Report was saved privately as `voxtant-audio-smoke-20261103-uid-v1/result.json`.
This establishes current local startup, not all hot-plug/race conditions or ASR quality.

Reproduction: `make audio-smoke AUDIO_SMOKE_DIR=/new/private/directory`.
The explicit check requires existing microphone permission, keeps local audio in
that new folder, and is excluded from verify. Ordinary UI smoke never records.
