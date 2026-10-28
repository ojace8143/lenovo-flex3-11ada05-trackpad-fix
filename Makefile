# Convenience wrapper around scripts/.
#
#   make build       # dump + patch this machine's DSDT (needs root)
#   make install     # install into the initramfs for this distro (needs root)
#   make verify      # post-reboot checks (exit 1 if the fix is not active)
#   make uninstall   # remove the override again (needs root)
#   make test        # offline patcher tests (no hardware needed)
#   make lint        # shellcheck + python syntax check
#
# Build/install/uninstall need root because they read firmware tables and write
# to /etc + /boot, so use:  sudo make build install
SHELL := /bin/bash
PYTHON ?= python3
DISTRO := $(shell bash -c '. scripts/lib/common.sh; detect_distro')

.PHONY: help build install verify uninstall test lint check clean

help:
	@echo 'Usage: sudo make <target>'
	@echo
	@echo '  build      dump + patch this machine'"'"'s DSDT (needs root)'
	@echo '  install    install into the initramfs for this distro (needs root)'
	@echo '  verify     post-reboot checks; exits 1 if the fix is not active'
	@echo '  uninstall  remove the override again (needs root)'
	@echo '  test       offline patcher tests (no hardware needed)'
	@echo '  lint       shellcheck + python syntax check'
	@echo '  check      lint + test'
	@echo '  clean      remove build/ and __pycache__'

build:
	@./scripts/build-dsdt.sh

install:
	@case "$(DISTRO)" in \
	  arch) \
	    if [ -f /etc/mkinitcpio.conf.d/omarchy_hooks.conf ] \
	        || command -v limine-mkinitcpio >/dev/null 2>&1; then \
	      ./scripts/install-omarchy.sh; \
	    else \
	      ./scripts/install-arch.sh; \
	    fi ;; \
	  debian) ./scripts/install-ubuntu.sh ;; \
	  void) ./scripts/install-void.sh ;; \
	  *) echo "unsupported distro '$(DISTRO)' - see docs/manual-install.md" >&2; exit 1 ;; \
	esac

uninstall:
	@case "$(DISTRO)" in \
	  arch) \
	    if [ -f /etc/mkinitcpio.conf.d/omarchy_hooks.conf ] \
	        || command -v limine-mkinitcpio >/dev/null 2>&1; then \
	      ./scripts/install-omarchy.sh --uninstall; \
	    else \
	      ./scripts/install-arch.sh --uninstall; \
	    fi ;; \
	  debian) ./scripts/install-ubuntu.sh --uninstall ;; \
	  void) ./scripts/install-void.sh --uninstall ;; \
	  *) echo "unsupported distro '$(DISTRO)' - see docs/manual-install.md" >&2; exit 1 ;; \
	esac

verify:
	@./scripts/verify.sh

test:
	@$(PYTHON) -m unittest discover -s tests -v

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "shellcheck not installed:" >&2; \
	  echo "  Arch/Omarchy: pacman -S shellcheck" >&2; \
	  echo "  Debian/Mint:  apt install shellcheck" >&2; \
	  echo "  Void:         xbps-install -S shellcheck" >&2; \
	  exit 1; }
	shellcheck -x scripts/*.sh scripts/lib/common.sh
	shellcheck -s sh scripts/hooks/initramfs-tools-acpi_override
	$(PYTHON) -m py_compile scripts/patch-dsdt.py
	@echo "lint: ok"

check: lint test

clean:
	rm -rf build
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
