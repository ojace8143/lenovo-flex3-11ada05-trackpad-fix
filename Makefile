# Convenience wrapper around scripts/.
#
#   make build       # dump + patch this machine's DSDT (needs root)
#   make install     # install into the initramfs for this distro (needs root)
#   make verify      # post-reboot checks; use sudo for the override checks
#   make uninstall   # remove the override again (needs root)
#   make purge       # remove everything this project ever installs (needs root)
#   make test        # offline patcher tests (no hardware needed)
#   make lint        # shellcheck + python syntax check
#   make distro      # show what this system looks like to the scripts
#
# Build/install/uninstall need root because they read firmware tables and write
# to /etc + /boot, so use:  sudo make build install
SHELL := /bin/bash
PYTHON ?= python3
DISTRO := $(shell bash -c '. scripts/lib/common.sh; detect_distro')
INITRAMFS := $(shell bash -c '. scripts/lib/common.sh; detect_initramfs')

.PHONY: help build install verify uninstall purge test lint check distro clean

help:
	@echo 'Usage: sudo make <target>'
	@echo
	@echo '  build      dump + patch this machine'"'"'s DSDT (needs root)'
	@echo '  install    install into the initramfs for this distro (needs root)'
	@echo '  verify     post-reboot checks; sudo for the override checks'
	@echo '  uninstall  remove the override again (needs root)'
	@echo '  purge      remove every artefact, whatever the distro (needs root)'
	@echo '  test       offline patcher tests (no hardware needed)'
	@echo '  lint       shellcheck + python syntax check'
	@echo '  check      lint + test'
	@echo '  distro     print detected distro and initramfs generator'
	@echo '  clean      remove build/ and __pycache__'

build:
	@./scripts/build-dsdt.sh

install:
	@case "$(INITRAMFS)" in \
	  initramfs-tools) ./scripts/install-ubuntu.sh ;; \
	  dracut) \
	    if [ "$(DISTRO)" = "void" ]; then \
	      ./scripts/install-void.sh; \
	    else \
	      ./scripts/install-dracut.sh; \
	    fi ;; \
	  mkinitcpio) \
	    if [ -f /etc/mkinitcpio.conf.d/omarchy_hooks.conf ] \
	        || command -v limine-mkinitcpio >/dev/null 2>&1; then \
	      ./scripts/install-omarchy.sh; \
	    else \
	      ./scripts/install-arch.sh; \
	    fi ;; \
	  *) echo "cannot tell which initramfs generator this system uses." >&2; \
	     echo "see docs/distros.md (dracut / initramfs-tools / mkinitcpio)." >&2; \
	     exit 1 ;; \
	esac

uninstall:
	@case "$(INITRAMFS)" in \
	  initramfs-tools) ./scripts/install-ubuntu.sh --uninstall ;; \
	  dracut) \
	    if [ "$(DISTRO)" = "void" ]; then \
	      ./scripts/install-void.sh --uninstall; \
	    else \
	      ./scripts/install-dracut.sh --uninstall; \
	    fi ;; \
	  mkinitcpio) \
	    if [ -f /etc/mkinitcpio.conf.d/omarchy_hooks.conf ] \
	        || command -v limine-mkinitcpio >/dev/null 2>&1; then \
	      ./scripts/install-omarchy.sh --uninstall; \
	    else \
	      ./scripts/install-arch.sh --uninstall; \
	    fi ;; \
	  *) echo "cannot tell which initramfs generator this system uses - use" >&2; \
	     echo "'sudo make purge' to remove everything instead." >&2; \
	     exit 1 ;; \
	esac

purge:
	@./scripts/uninstall-all.sh

verify:
	@./scripts/verify.sh

distro:
	@echo "distro:    $(DISTRO)"
	@echo "initramfs: $(INITRAMFS)"

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
