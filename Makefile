APP      := monica.app
APPS_DIR := /Applications

# The nix devshell / profile exports SDKROOT pointing at the nix apple-sdk,
# which the system CLT compiler refuses ("SDK is not supported by the
# compiler" / "no such module 'SwiftShims'"). This project deliberately
# builds with the system toolchain (see AGENTS.md), so strip those vars from
# everything make runs.
unexport SDKROOT
unexport DEVELOPER_DIR

.PHONY: build run release app install link unlink format lint clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build a debug binary
	swift build

run: ## Build and launch (dev)
	swift run

release: ## Build an optimized release binary
	swift build -c release

app: ## Build monica.app bundle
	./build-app.sh

install: app ## Copy monica.app into /Applications
	rm -rf "$(APPS_DIR)/$(APP)"
	cp -r "$(APP)" "$(APPS_DIR)/$(APP)"
	@echo "Installed $(APPS_DIR)/$(APP)"

link: app ## Symlink monica.app into /Applications (points at this build)
	rm -rf "$(APPS_DIR)/$(APP)"
	ln -s "$(CURDIR)/$(APP)" "$(APPS_DIR)/$(APP)"
	@echo "Linked $(APPS_DIR)/$(APP) -> $(CURDIR)/$(APP)"

unlink: ## Remove monica.app from /Applications
	rm -rf "$(APPS_DIR)/$(APP)"
	@echo "Removed $(APPS_DIR)/$(APP)"

format: ## Auto-format sources
	swift format --in-place --recursive Sources

lint: ## Check formatting
	swift format lint --strict --recursive Sources

clean: ## Remove build artifacts
	rm -rf .build "$(APP)"
