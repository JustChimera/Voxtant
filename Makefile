SHELL := /bin/sh
export CLANG_MODULE_CACHE_PATH := $(TMPDIR)lecture-translate-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE := $(TMPDIR)lecture-translate-swift-cache
SWIFT_FLAGS := --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security
.PHONY: build dev test test-one lint typecheck verify
build:
	sh scripts/build-app.sh
dev: build
	open "dist/Voxtant.app"
test:
	swift test $(SWIFT_FLAGS)
test-one:
	swift test $(SWIFT_FLAGS) --filter "$(FILTER)"
lint:
	plutil -lint scripts/Info.plist
	sh -n scripts/build-app.sh
typecheck:
	swift build $(SWIFT_FLAGS)
verify: test lint build
