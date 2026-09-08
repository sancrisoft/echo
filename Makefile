# Echo v2 — the commands the repository is worked with. `make help` lists them.
#
# Package tests run with `swift test` and no host app; only AppTests is hosted
# in Echo.app (ADR-004). Builds are arm64 and ad-hoc signed, like CI and the
# release.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PACKAGES        := $(sort $(notdir $(wildcard Packages/*)))
PACKAGE_SOURCES := $(wildcard Packages/*/Sources) $(wildcard Packages/*/Tests)
DERIVED         := build
DESTINATION     := platform=macOS,arch=arm64
XCODEBUILD      := xcodebuild -project Echo.xcodeproj -scheme Echo -destination '$(DESTINATION)' \
                   -derivedDataPath $(DERIVED) -skipMacroValidation -skipPackagePluginValidation \
                   CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
APP             := $(DERIVED)/Build/Products/Debug/Echo.app

.PHONY: help build run test test-packages test-package test-app lint format check-boundaries clean

help: ## List the targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build Echo.app (Debug)
	$(XCODEBUILD) -quiet build

run: build ## Build and launch Echo.app
	open $(APP)

test: test-packages test-app ## Every test: each package with swift test, then the hosted AppTests

test-packages: ## swift test for every package under Packages/
	@for package in $(PACKAGES); do \
		echo "==> $$package"; \
		swift test --package-path Packages/$$package || exit 1; \
	done

test-package: ## One package: make test-package P=Meetings
	@test -n "$(P)" || { echo "usage: make test-package P=<PackageName>"; exit 2; }
	swift test --package-path Packages/$(P)

test-app: ## The hosted AppTests bundle (serial: it runs inside Echo.app)
	$(XCODEBUILD) -quiet test -only-testing:AppTests -parallel-testing-enabled NO

lint: check-boundaries ## swift-format lint (strict) + the boundary rules
	swift format lint --strict --recursive App AppTests $(PACKAGE_SOURCES)

format: ## swift-format in place
	swift format --in-place --recursive App AppTests $(PACKAGE_SOURCES)

check-boundaries: ## Dependency direction, engine/UI separation, forbidden patterns
	scripts/check_boundaries.sh

clean: ## Remove build products
	rm -rf $(DERIVED)
	@for package in $(PACKAGES); do rm -rf Packages/$$package/.build; done
