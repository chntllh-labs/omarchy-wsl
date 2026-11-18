# Omarchy WSL: build, install and test entry points.
#
# rootfs.manifest is the single list of files this repository installs into
# the root filesystem; scripts/install-manifest.sh applies it.
#
#   make install-rootfs DESTDIR=/path/to/rootfs   every runtime file (100%)
#   make install-pkg    DESTDIR=$pkgdir           what the omarchy-wsl package owns
#   make verify-rootfs  ROOT=/path/to/rootfs      re-check installed files (sha256 + mode)
#   make manifest                                 print the resolved manifest
#   make test                                     all suites, strict (tests/run-all.sh)
#   make test-container                           the same inside tests/ci/Containerfile
#   make lint                                     shellcheck + PowerShell parse
#   make image ARCH=arm64|x86_64                  reproducible .wsl (Linux + Docker/Podman)

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

DESTDIR ?=
ROOT ?= /
ARCH ?= $(shell uname -m)
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)
OMARCHY_WSL_GIT_SHA ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
OMARCHY_WSL_PKGVER ?=
CONTAINER_ENGINE ?= $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)

INSTALL_MANIFEST := scripts/install-manifest.sh
MANIFEST_ENV := SOURCE_DATE_EPOCH='$(SOURCE_DATE_EPOCH)' OMARCHY_WSL_GIT_SHA='$(OMARCHY_WSL_GIT_SHA)' \
	OMARCHY_WSL_PKGVER='$(OMARCHY_WSL_PKGVER)'

.PHONY: help install-pkg install-rootfs verify-rootfs manifest test test-container lint image clean

help:
	@sed -n '3,14p' Makefile | sed 's/^# \{0,1\}//'

define require_destdir
	@if [[ -z "$(DESTDIR)" ]]; then echo "make $@: set DESTDIR (use DESTDIR=/ only inside an image build)" >&2; exit 2; fi
endef

install-pkg:
	$(require_destdir)
	@$(MANIFEST_ENV) $(INSTALL_MANIFEST) install --scope pkg --destdir "$(abspath $(DESTDIR))"

install-rootfs:
	$(require_destdir)
	@$(MANIFEST_ENV) $(INSTALL_MANIFEST) install --scope rootfs --destdir "$(abspath $(DESTDIR))"

verify-rootfs:
	@$(INSTALL_MANIFEST) verify --root "$(ROOT)"

manifest:
	@$(INSTALL_MANIFEST) list --scope rootfs

test:
	@tests/run-all.sh

test-container:
	@[[ -n "$(CONTAINER_ENGINE)" ]] || { echo "docker or podman required" >&2; exit 2; }
	$(CONTAINER_ENGINE) build -t omarchy-wsl-test -f tests/ci/Containerfile tests/ci
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/src" -w /src -e OMW_STRICT=1 omarchy-wsl-test tests/run-all.sh

lint:
	@tests/run-all.sh --lint-only

image:
	@scripts/build-reproducible-rootfs.sh "$(ARCH)"

clean:
	rm -rf dist .pytest_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
