SHELL := /bin/sh
export CLANG_MODULE_CACHE_PATH := $(TMPDIR)lecture-translate-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE := $(TMPDIR)lecture-translate-swift-cache
SWIFT_FLAGS := --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security
.PHONY: build release install dev test test-one lint typecheck verify ui-smoke
build:
	sh scripts/build-app.sh
release:
	sh scripts/package-release.sh
install: release
	sh scripts/install-app.sh
dev: build
	open "dist/Voxtant.app"
test:
	swift test $(SWIFT_FLAGS)
test-one:
	swift test $(SWIFT_FLAGS) --filter "$(FILTER)"
lint:
	plutil -lint scripts/Info.plist
	sh -n scripts/build-app.sh scripts/build-icon.sh scripts/package-release.sh scripts/install-app.sh
typecheck:
	swift build $(SWIFT_FLAGS)
verify: test eval-test lint build

ui-smoke: build
	python3 -c 'from pathlib import Path; Path(".build/ui-smoke/result.json").unlink(missing_ok=True)'
	"dist/Voxtant.app/Contents/MacOS/Voxtant" --ui-smoke-dir "$(CURDIR)/.build/ui-smoke"
	python3 -c 'import json; r=json.load(open(".build/ui-smoke/result.json")); print(r); assert r["passed"]'

# Validation data and API runs are explicit and never part of verify.
.PHONY: eval-test eval-build eval-dataset eval-prepare eval-run eval-report
eval-test:
	python3 -m unittest discover -s Tests/ValidationTests -v
eval-build:
	swift build $(SWIFT_FLAGS) --product VoxtantEval
eval-dataset:
	python3 scripts/validation.py build --dataset "$(DATASET)" $(if $(PILOT_MANIFEST),--pilot-manifest "$(PILOT_MANIFEST)",)
eval-prepare: eval-build
	.build/debug/VoxtantEval prepare "$(DATASET)"
eval-run: eval-build
	python3 scripts/validation.py run --dataset "$(DATASET)" --asr-model "$(or $(ASR_MODEL),elevenlabs/scribe-v2)" --translation-model "$(or $(TRANSLATION_MODEL),openai/gpt-4.1-mini)" $(EVAL_ARGS)
eval-report:
	python3 scripts/validation.py report --dataset "$(DATASET)"

.PHONY: eval-auto eval-auto-report
eval-auto:
	python3 scripts/auto_validation.py run --dataset "$(DATASET)" $(EVAL_ARGS)
eval-auto-report:
	python3 scripts/auto_validation.py report --dataset "$(DATASET)" $(EVAL_ARGS)

# Paid ASR pool comparison; separate from verify and human reference generation.
.PHONY: eval-candidates eval-candidates-report
eval-candidates:
	python3 scripts/candidate_validation.py run --dataset "$(DATASET)" $(EVAL_ARGS)
eval-candidates-report:
	python3 scripts/candidate_validation.py report --dataset "$(DATASET)" $(EVAL_ARGS)

# Bounded paired context experiment, using only the selected quality shortlist.
.PHONY: eval-context eval-context-report
eval-context:
	python3 scripts/context_validation.py run --dataset "$(DATASET)" $(EVAL_ARGS)
eval-context-report:
	python3 scripts/context_validation.py report --dataset "$(DATASET)" $(EVAL_ARGS)

# Independent authored-script regression corpus; network runs remain explicit.
.PHONY: quality-build quality-run quality-report quality-freeze quality-compare quality-status
quality-build: eval-build
	python3 scripts/quality_regression.py build --dataset "$(DATASET)"
quality-run: eval-build
	python3 scripts/quality_regression.py run --dataset "$(DATASET)" --run-id "$(or $(RUN_ID),baseline-v1)"
quality-report:
	python3 scripts/quality_regression.py report --dataset "$(DATASET)" --run-id "$(or $(RUN_ID),baseline-v1)"
quality-freeze:
	python3 scripts/quality_regression.py freeze --dataset "$(DATASET)" --run-id "$(or $(RUN_ID),baseline-v1)" --baseline "$(or $(BASELINE),v1)"
quality-compare:
	python3 scripts/quality_regression.py compare --dataset "$(DATASET)" --run-id "$(RUN_ID)" --baseline "$(or $(BASELINE),v1)"
quality-status:
	python3 scripts/quality_regression.py status --dataset "$(DATASET)" --baseline "$(or $(BASELINE),v1)"

# Explicit authored-text translator comparison; no personal audio/text is sent.
.PHONY: translation-eval translation-report
translation-eval: eval-build
	python3 scripts/translation_validation.py run --output "$(OUTPUT)" $(EVAL_ARGS)
translation-report:
	python3 scripts/translation_validation.py report --output "$(OUTPUT)"

# Explicit local microphone check; never sends audio or reads credentials.
.PHONY: audio-smoke
audio-smoke: build
	@test -n "$(AUDIO_SMOKE_DIR)" || (echo 'Set AUDIO_SMOKE_DIR to a new private directory outside the repo'; exit 1)
	"dist/Voxtant.app/Contents/MacOS/Voxtant" --audio-smoke-dir "$(AUDIO_SMOKE_DIR)"
	python3 -c 'import json; r=json.load(open("$(AUDIO_SMOKE_DIR)/result.json")); print(r); assert r["passed"]'

# Local acoustic regression, without microphone, Keychain or APIs.
.PHONY: speech-gate-eval
speech-gate-eval: eval-build
	.build/debug/VoxtantEval speech-gate "$(DATASET)" "$(OUTPUT)"

# Explicit bounded ASR option probe on separately authorized saved clips.
.PHONY: asr-options-eval
asr-options-eval: eval-build
	python3 scripts/asr_options_validation.py --dataset "$(DATASET)" --output "$(OUTPUT)"

# Public CBR rate only, no audio or credentials.
.PHONY: exchange-rate-check
exchange-rate-check: eval-build
	.build/debug/VoxtantEval exchange-rate "$(OUTPUT)"
