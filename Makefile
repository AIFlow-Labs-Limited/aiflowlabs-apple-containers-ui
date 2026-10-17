# Container Desktop — build helpers. `make help` lists targets.
APP_NAME      ?= Container Desktop
BUNDLE_ID     ?= io.aiflowlabs.containerdesktop
VERSION       ?= 0.1.0
BUILD_DIR     ?= build
CONFIG        ?= release
APP           := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: help build test app run run-mock clean format

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

build: ## swift build (debug)
	swift build

test: ## swift test
	swift test

app: ## Build the .app bundle (release) — implemented in scripts/bundle.sh
	scripts/bundle.sh "$(APP_NAME)" "$(BUNDLE_ID)" "$(VERSION)" "$(CONFIG)" "$(BUILD_DIR)"

run: app ## Build and launch against the real `container` CLI
	open "$(APP)"

run-mock: app ## Build and launch with the fixture-backed mock backend
	CONTAINER_DESKTOP_BACKEND=mock open "$(APP)" --env CONTAINER_DESKTOP_BACKEND=mock

format: ## swift-format in place
	swift format -i -r Sources Tests

clean: ## Remove build products
	rm -rf .build "$(BUILD_DIR)"
