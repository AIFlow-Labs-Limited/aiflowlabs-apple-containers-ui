# Container Desktop — build helpers. `make help` lists targets.
APP_NAME      ?= Container Desktop
BUNDLE_ID     ?= io.aiflowlabs.containerdesktop
VERSION       ?= 0.1.0
BUILD_DIR     ?= build
CONFIG        ?= release
APP           := $(BUILD_DIR)/$(APP_NAME).app
DMG           := $(BUILD_DIR)/$(subst $(subst ,, ),-,$(APP_NAME))-$(VERSION)-arm64.dmg
# SIGN_IDENTITY (default "-" = ad-hoc) and NOTARY_PROFILE are read from the environment by the scripts.

.PHONY: help build test app run run-mock dmg notarize icon lint format check release clean

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

build: ## swift build (debug)
	swift build

test: ## swift test
	swift test

app: ## Build the signed .app bundle (release) → build/Container Desktop.app
	scripts/bundle.sh "$(APP_NAME)" "$(BUNDLE_ID)" "$(VERSION)" "$(CONFIG)" "$(BUILD_DIR)"

run: app ## Build and launch against the real `container` CLI
	open "$(APP)"

run-mock: app ## Build and launch with the fixture-backed mock backend
	CONTAINER_DESKTOP_BACKEND=mock open "$(APP)" --env CONTAINER_DESKTOP_BACKEND=mock

dmg: app ## Build build/Container-Desktop-<version>-arm64.dmg (verified)
	scripts/dmg.sh "$(APP_NAME)" "$(VERSION)" "$(BUILD_DIR)"

notarize: ## Notarize + staple the DMG (no-op without NOTARY_PROFILE)
	scripts/notarize.sh "$(DMG)"

icon: ## Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
	scripts/make-icon.sh

lint: ## swift format lint --strict (any style violation fails; fix with `make format`)
	swift format lint -r Sources Tests --strict

format: ## swift-format in place
	swift format -i -r Sources Tests

check: build test lint ## Build + test + lint (run before every PR)

release: ## Bump version, update CHANGELOG, tag vX.Y.Z (no push). Usage: make release VERSION=x.y.z
	@test -n "$(filter command line,$(origin VERSION))" || { echo "usage: make release VERSION=x.y.z"; exit 64; }
	scripts/release.sh "$(VERSION)"

clean: ## Remove build products (refuses an empty, root, home or parent BUILD_DIR)
	@case "$(strip $(BUILD_DIR))" in ""|/|.|..|./|../|~|~/|"$(HOME)"|"$(HOME)/") \
		echo "error: refusing to rm -rf BUILD_DIR='$(BUILD_DIR)'" >&2; exit 1;; esac
	rm -rf .build "$(BUILD_DIR)"
