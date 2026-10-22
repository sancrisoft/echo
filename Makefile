# Echo v2 — the commands the repository is worked with. `make help` lists them.
#
# Package tests run with `swift test` and no host app; only AppTests is hosted
# in Echo.app (ADR-004). `test-packages` builds each package on its own, which
# proves every Package.swift declares what it imports; `test-packages-shared`
# shares one build between them, for speed. Builds are arm64 and ad-hoc
# signed, like CI and the release.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PACKAGES        := $(sort $(notdir $(wildcard Packages/*)))
PACKAGE_SOURCES := $(wildcard Packages/*/Sources) $(wildcard Packages/*/Tests)
DERIVED         := build
DESTINATION     := platform=macOS,arch=arm64
XCODEBUILD      := xcodebuild -project Echo.xcodeproj -scheme Echo -destination '$(DESTINATION)' \
                   -derivedDataPath $(DERIVED) -skipMacroValidation -skipPackagePluginValidation \
                   CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
SHARED_SCRATCH  := $(DERIVED)/spm
NO_DEBUG_INFO   := -Xswiftc -gnone -Xcc -g0 -Xcxx -g0
APP             := $(DERIVED)/Build/Products/Debug/Echo.app

.PHONY: help build run test test-packages test-packages-shared test-package test-app lint format check-boundaries app-icon clean

help: ## List the targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-22s\033[0m %s\n", $$1, $$2}'

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

# Every package's tests through one scratch path, so a dependency several
# packages share compiles once (MLX would otherwise compile in four). The pins
# must agree across packages for that to hold. No debug info: nobody attaches
# a debugger to this run. A shared build can lend a module to a package that
# never declared it, so this does not replace `test-packages`.
test-packages-shared: ## Every package's tests in one shared build, dependencies compiled once
	@for package in $(PACKAGES); do \
		echo "==> $$package"; \
		swift test --package-path Packages/$$package --scratch-path $(SHARED_SCRATCH) $(NO_DEBUG_INFO) || exit 1; \
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

app-icon: ## Render App/Assets.xcassets/AppIcon.appiconset from the mark's geometry
	@mkdir -p $(DERIVED)
	swiftc -swift-version 6 -parse-as-library -O -o $(DERIVED)/generate_app_icon \
		Packages/DesignSystem/Sources/DesignSystem/EchoMarkGeometry.swift scripts/generate_app_icon.swift
	$(DERIVED)/generate_app_icon App/Assets.xcassets/AppIcon.appiconset

clean: ## Remove build products
	rm -rf $(DERIVED)
	@for package in $(PACKAGES); do rm -rf Packages/$$package/.build; done
