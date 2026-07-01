# cmdloop — developer Makefile
# Run `make` or `make help` to list routes.

BINARY       := cmdloop
PREFIX       := /usr/local/bin
CONFIG_DIR   := $(HOME)/.config/cmd-loop
LOGS_DIR     := $(CONFIG_DIR)/logs
AGENTS_DIR   := $(HOME)/Library/LaunchAgents
DOMAIN       := gui/$(shell id -u)

# A deliberately non-cmdloop, non-noise label so it shows up in the app as an
# adoptable "external" launchd agent (used by `make test-agent`).
TEST_LABEL   := com.example.cmdloop-test
TEST_PLIST   := $(AGENTS_DIR)/$(TEST_LABEL).plist
TEST_OUT     := /tmp/cmdloop-test.log

.DEFAULT_GOAL := help

# ----------------------------------------------------------------------------
# Build & run
# ----------------------------------------------------------------------------

.PHONY: build
build: ## Debug build
	swift build

.PHONY: release
release: ## Release build
	swift build -c release

.PHONY: run
run: ## Run the menu bar app in the foreground (Ctrl-C to stop)
	swift run cmdloop --daemon

.PHONY: run-bg
run-bg: ## Launch detached in the background (like a normal start)
	swift run cmdloop

.PHONY: version
version: ## Print the app version
	swift run cmdloop --version

.PHONY: clean
clean: ## Remove build artifacts
	swift package clean
	rm -rf .build

# ----------------------------------------------------------------------------
# Tests / checks
# ----------------------------------------------------------------------------

.PHONY: test
test: ## Run XCTest (needs full Xcode); falls back to build with Command Line Tools
	@if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then \
		swift test; \
	else \
		echo "==> No full Xcode found (XCTest unavailable). Running 'swift build' instead."; \
		swift build; \
	fi

.PHONY: check
check: build ## Alias for build — the local verification gate
	@echo "==> Build OK"

# ----------------------------------------------------------------------------
# Install / uninstall (mirrors install.sh / uninstall.sh)
# ----------------------------------------------------------------------------

.PHONY: install
install: release ## Build release, install binary, load login agent
	cp .build/release/$(BINARY) $(PREFIX)/$(BINARY)
	cp com.cmdloop.plist $(AGENTS_DIR)/com.cmdloop.plist
	launchctl load $(AGENTS_DIR)/com.cmdloop.plist
	@echo "==> Installed to $(PREFIX)/$(BINARY) and loaded login agent."

.PHONY: uninstall
uninstall: ## Stop, unload login agent, remove installed binary
	-launchctl unload $(AGENTS_DIR)/com.cmdloop.plist 2>/dev/null
	rm -f $(AGENTS_DIR)/com.cmdloop.plist
	rm -f $(PREFIX)/$(BINARY)
	@echo "==> Uninstalled."

# ----------------------------------------------------------------------------
# launchd inspection / testing helpers
# ----------------------------------------------------------------------------

.PHONY: agents
agents: ## List cmdloop-managed launchd agents (loaded + on disk)
	@echo "== launchctl list =="
	@launchctl list | grep -i cmdloop || echo "(none loaded)"
	@echo "== ~/Library/LaunchAgents =="
	@ls -1 $(AGENTS_DIR)/com.cmdloop.*.plist 2>/dev/null || echo "(no managed plists)"

.PHONY: logs
logs: ## Tail the most recent run-log file
	@f=$$(ls -t $(LOGS_DIR)/*/*.log 2>/dev/null | head -1); \
	if [ -n "$$f" ]; then echo "==> tailing $$f"; tail -f "$$f"; else echo "(no run logs yet)"; fi

.PHONY: logs-list
logs-list: ## List all recorded runs, newest first
	@ls -t $(LOGS_DIR)/*/*.log 2>/dev/null || echo "(no run logs yet)"

.PHONY: test-agent
test-agent: ## Create + load a throwaway EXTERNAL launchd agent (fires every 60s)
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(TEST_LABEL)</string>' \
	  '  <key>ProgramArguments</key>' \
	  '  <array><string>/bin/zsh</string><string>-l</string><string>-c</string>' \
	  '  <string>date >> $(TEST_OUT)</string></array>' \
	  '  <key>StartInterval</key><integer>60</integer>' \
	  '</dict></plist>' > $(TEST_PLIST)
	-launchctl bootout $(DOMAIN)/$(TEST_LABEL) 2>/dev/null
	launchctl bootstrap $(DOMAIN) $(TEST_PLIST)
	@echo "==> Loaded $(TEST_LABEL). Open cmdloop — it should appear as an external 'launchd job'."
	@echo "    Watch it fire: tail -f $(TEST_OUT)"

.PHONY: clean-test-agent
clean-test-agent: ## Unload + remove the throwaway external agent
	-launchctl bootout $(DOMAIN)/$(TEST_LABEL) 2>/dev/null
	rm -f $(TEST_PLIST) $(TEST_OUT)
	@echo "==> Removed $(TEST_LABEL)."

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
