REBAR3 ?= rebar3
CARGO ?= cargo
REBAR_CACHE_DIR ?= $(CURDIR)/.cache/rebar3
CARGO_TARGET_DIR ?= $(CURDIR)/_build/cargo
CCACHE_DIR ?= $(CURDIR)/.cache/ccache
COMPANION_MANIFEST := apps/wfcompanion/Cargo.toml
VERSION := $(strip $(shell cat VERSION))
PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
PREVIEW_SIZE ?= 2560x1440

export REBAR_CACHE_DIR
export CARGO_TARGET_DIR
export CCACHE_DIR

.PHONY: all build dev prod erlang cli daemon mcp companion \
	dev-erlang prod-erlang dev-companion prod-companion links \
	debug-bridge native-bridges previews preview-videos aleca-layout-setup reference-previews \
	native-compile-commands test test-erlang test-companion check fmt-check package clean

all: dev
build: dev prod native-compile-commands

dev: dev-erlang dev-companion links

prod: prod-erlang prod-companion links

erlang cli daemon mcp: dev-erlang

companion: dev-companion

dev-erlang:
	$(REBAR3) escriptize
	$(REBAR3) release
	./scripts/stage-erlang dev

prod-erlang:
	$(REBAR3) as prod escriptize
	$(REBAR3) as prod release
	./scripts/stage-erlang prod

dev-companion:
	./scripts/build-companion dev

prod-companion:
	./scripts/build-companion prod

links:
	ln -sfn dev/bin/wfcli wfclid
	ln -sfn dev/bin/wfdaemon wfdaemond
	ln -sfn dev/bin/wfcompanion wfcompaniond
	ln -sfn prod/bin/wfcli wfcli
	ln -sfn prod/bin/wfdaemon wfdaemon
	ln -sfn prod/bin/wfcompanion wfcompanion

debug-bridge:
	./scripts/build-debug-bridge

native-bridges: debug-bridge

native-compile-commands:
	./scripts/native-compile-commands

previews: dev-companion
	WFCOMPANION_PREVIEW_SIZE=$(PREVIEW_SIZE) dev/bin/wfcompanion preview --all previews

preview-videos: dev-companion
	WFCOMPANION_PREVIEW_SIZE=$(PREVIEW_SIZE) dev/bin/wfcompanion preview --animate-all previews

aleca-layout-setup:
	./scripts/setup-aleca-layout

reference-previews:
	ALECA_LAYOUT_SIZE=$(PREVIEW_SIZE) node tools/aleca-layout/index.mjs
	ALECA_LAYOUT_SIZE=$(PREVIEW_SIZE) node tools/aleca-layout/suggestions.mjs

test: test-erlang test-companion

test-erlang:
	./scripts/test-quiet eunit
	./scripts/test-quiet ct

test-companion: native-bridges
	$(CARGO) test --locked --quiet --manifest-path $(COMPANION_MANIFEST)

fmt-check:
	$(CARGO) fmt --manifest-path $(COMPANION_MANIFEST) --check

check: fmt-check test dev prod

package: prod
	mkdir -p releases
	rm -f releases/wfcli-$(VERSION)-$(PLATFORM).tar.gz releases/wfcli-$(VERSION)-$(PLATFORM).zip
	tar -C prod -czf releases/wfcli-$(VERSION)-$(PLATFORM).tar.gz .
	cd prod && zip -qr ../releases/wfcli-$(VERSION)-$(PLATFORM).zip .

clean:
	rm -rf _build dev prod
