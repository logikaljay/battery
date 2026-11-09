PREFIX ?= $(HOME)/.local

install:            ## CLI + bar widget
	PREFIX=$(PREFIX) ./install.sh

install-cli:        ## CLI only
	PREFIX=$(PREFIX) ./install.sh --cli-only

uninstall:
	PREFIX=$(PREFIX) ./install.sh --uninstall

.PHONY: install install-cli uninstall
