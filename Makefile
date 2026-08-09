REBAR3 ?= rebar3
CARGO ?= cargo
REBAR_CACHE_DIR ?= $(CURDIR)/.cache/rebar3
CARGO_TARGET_DIR ?= $(CURDIR)/_build/cargo
SCCACHE ?= $(shell command -v sccache 2>/dev/null)
SCCACHE_BASEDIRS ?= $(CURDIR)
SCCACHE_DIR ?= $(CURDIR)/.cache/sccache
SCCACHE_SERVER_UDS ?= $(CURDIR)/.cache/sccache.sock
LLVM_ROOT ?= $(shell brew --prefix llvm 2>/dev/null)
NINJA ?= $(shell command -v ninja 2>/dev/null)

ifeq ($(origin CC),default)
CC := $(if $(LLVM_ROOT),$(LLVM_ROOT)/bin/clang,clang)
endif
ifeq ($(origin CXX),default)
CXX := $(if $(LLVM_ROOT),$(LLVM_ROOT)/bin/clang++,clang++)
endif

COMPANION_MANIFEST := apps/wfcompanion/Cargo.toml
VERSION := $(strip $(shell cat VERSION))
PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
PREVIEW_MEDIA ?= all
PREVIEW_SETS ?= companion reference
PREVIEW_SCENES ?= all
PREVIEW_RESOLUTIONS ?= 1920x1080 2560x1440
PREVIEW_DEPS = $(if $(findstring companion,$(PREVIEW_SETS)),dev-companion)
ICON_OPTICS_SCALE ?= 1.25
ICON_OPTICS_OUTPUT ?= $(CURDIR)/previews/optics
ICON_OPTICS_CONFIG ?= $(CURDIR)/tools/icon-optics/foundry.json

export REBAR_CACHE_DIR
export CARGO_TARGET_DIR
export SCCACHE_BASEDIRS
export SCCACHE_DIR
export SCCACHE_SERVER_UDS
export CC CXX

ifneq ($(strip $(SCCACHE)),)
RUSTC_WRAPPER ?= $(SCCACHE)
CMAKE_C_COMPILER_LAUNCHER ?= $(SCCACHE)
CMAKE_CXX_COMPILER_LAUNCHER ?= $(SCCACHE)
export RUSTC_WRAPPER CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
endif

.PHONY: all build dev prod erlang cli daemon mcp companion gui gui-dev gui-prod sccache-start \
	gui-configure-dev gui-configure-prod gui-reconfigure gui-reconfigure-dev gui-reconfigure-prod \
	dev-erlang prod-erlang dev-companion prod-companion links \
	debug-bridge native-bridges previews icon-optics aleca-layout-setup fix-executables \
	native-compile-commands test test-erlang test-companion test-gui check fmt-check xref package clean

all: dev
build: dev prod native-compile-commands

sccache-start:
ifneq ($(strip $(SCCACHE)),)
	@mkdir -p "$(dir $(SCCACHE_SERVER_UDS))"
	@if ! $(SCCACHE) --start-server >/dev/null 2>&1; then \
		$(SCCACHE) --show-stats >/dev/null; \
	fi
endif

dev: dev-erlang dev-companion gui-dev links

prod: prod-erlang prod-companion gui-prod links

erlang cli daemon mcp: dev-erlang

companion: dev-companion

gui: gui-dev

gui-configure-dev: sccache-start
	test -n "$(LLVM_ROOT)"
	test -n "$(NINJA)"
	LLVM_ROOT="$(LLVM_ROOT)" cmake --preset gui-dev --log-level=WARNING -DCMAKE_MAKE_PROGRAM="$(NINJA)"

gui-dev: gui-configure-dev
	LLVM_ROOT="$(LLVM_ROOT)" cmake --build --preset gui-dev
	rm -rf dev/lib dev/Qt6
	LLVM_ROOT="$(LLVM_ROOT)" cmake --install _build/cmake/gui-dev

gui-configure-prod: sccache-start
	test -n "$(LLVM_ROOT)"
	test -n "$(NINJA)"
	LLVM_ROOT="$(LLVM_ROOT)" cmake --preset gui-prod --log-level=WARNING -DCMAKE_MAKE_PROGRAM="$(NINJA)"

gui-prod: gui-configure-prod
	LLVM_ROOT="$(LLVM_ROOT)" cmake --build --preset gui-prod
	rm -rf prod/lib prod/Qt6
	LLVM_ROOT="$(LLVM_ROOT)" cmake --install _build/cmake/gui-prod

gui-reconfigure: gui-reconfigure-dev gui-reconfigure-prod

gui-reconfigure-dev: sccache-start
	test -n "$(LLVM_ROOT)"
	test -n "$(NINJA)"
	LLVM_ROOT="$(LLVM_ROOT)" cmake --fresh --preset gui-dev --log-level=WARNING -DCMAKE_MAKE_PROGRAM="$(NINJA)"

gui-reconfigure-prod: sccache-start
	test -n "$(LLVM_ROOT)"
	test -n "$(NINJA)"
	LLVM_ROOT="$(LLVM_ROOT)" cmake --fresh --preset gui-prod --log-level=WARNING -DCMAKE_MAKE_PROGRAM="$(NINJA)"

dev-erlang:
	$(REBAR3) escriptize
	rm -rf _build/default/rel/wfdaemon
	$(REBAR3) release
	./scripts/stage-erlang dev

prod-erlang:
	$(REBAR3) as prod escriptize
	rm -rf _build/prod/rel/wfdaemon
	$(REBAR3) as prod release
	./scripts/stage-erlang prod

dev-companion: sccache-start
	./scripts/build-companion dev

prod-companion: sccache-start
	./scripts/build-companion prod

links:
	ln -sfn dev/bin/wfcli wfclid
	ln -sfn dev/bin/wfdaemon wfdaemond
	ln -sfn dev/bin/wfcompanion wfcompaniond
	ln -sfn dev/bin/wfgui wfguid
	ln -sfn prod/bin/wfcli wfcli
	ln -sfn prod/bin/wfdaemon wfdaemon
	ln -sfn prod/bin/wfcompanion wfcompanion
	ln -sfn prod/bin/wfgui wfgui

debug-bridge: sccache-start
	./scripts/build-debug-bridge

native-bridges: debug-bridge

native-compile-commands: sccache-start
	./scripts/native-compile-commands

previews: $(PREVIEW_DEPS)
	PREVIEW_MEDIA='$(PREVIEW_MEDIA)' \
	PREVIEW_SETS='$(PREVIEW_SETS)' \
	PREVIEW_SCENES='$(PREVIEW_SCENES)' \
	PREVIEW_RESOLUTIONS='$(PREVIEW_RESOLUTIONS)' \
	./scripts/generate-previews

icon-optics: gui-configure-dev
	LLVM_ROOT="$(LLVM_ROOT)" cmake --build --preset gui-dev --target wfgui_icon_optics
	QT_QPA_PLATFORM=offscreen _build/cmake/gui-dev/apps/wfgui/wfgui-icon-optics \
		--config "$(ICON_OPTICS_CONFIG)" --ui-scale "$(ICON_OPTICS_SCALE)" \
		--output-dir "$(ICON_OPTICS_OUTPUT)"

aleca-layout-setup:
	./scripts/setup-aleca-layout

fix-executables:
	bash ./scripts/fix-executables

test: test-erlang test-companion test-gui

test-erlang:
	./scripts/test-quiet eunit
	./scripts/test-quiet ct

test-companion: native-bridges
	$(CARGO) test --locked --quiet --manifest-path $(COMPANION_MANIFEST)

test-gui:
	./scripts/test-quiet gui

fmt-check:
	$(CARGO) fmt --manifest-path $(COMPANION_MANIFEST) --check

xref:
	$(REBAR3) xref

check: fmt-check xref test dev prod

package: prod
	mkdir -p releases
	rm -f releases/wfcli-$(VERSION)-$(PLATFORM).tar.gz releases/wfcli-$(VERSION)-$(PLATFORM).zip
	tar -C prod -czf releases/wfcli-$(VERSION)-$(PLATFORM).tar.gz .
	cd prod && zip -qr ../releases/wfcli-$(VERSION)-$(PLATFORM).zip .

clean:
	rm -rf _build dev prod
