.PHONY: all clean opencode install

MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# Determine container engine (podman or docker)
CONTAINER_ENGINE := $(shell which podman 2>/dev/null || which docker 2>/dev/null)

# UID/GID
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

# Tools to install in to the containers with apt-get
LOCAL_TOOLS := "git curl jq ripgrep vim nano make zip unzip ssh-client wget tree imagemagick build-essential python3 python3-pip"


# Ensure we have a container engine
ifeq ($(CONTAINER_ENGINE),)
$(error No container engine (podman/docker) found in PATH)
endif

all: opencode install

opencode:
	@echo "Building opencode"
	$(CONTAINER_ENGINE) build \
		--build-arg HOST_UID=$(HOST_UID) \
		--build-arg HOST_GID=$(HOST_GID) \
		--build-arg LOCAL_TOOLS=$(LOCAL_TOOLS) \
		-t opencode .

install:
	@echo "Create state and share for opencode"
	mkdir -p "$(HOME)/.local/state/opencode" && mkdir -p "$(HOME)/.local/share/opencode"
	@echo "Add run_opencode to ~/.local/bin"
	[ -L "$(HOME)/.local/bin/run_opencode" ] || ( chmod +x "$(MAKEFILE_DIR)/run_opencode" && ln -s "$(MAKEFILE_DIR)/run_opencode" ~/.local/bin/run_opencode )
	mkdir -p "$(HOME)/.config/opencode" && cp "$(MAKEFILE_DIR)/opencode_template.jsonc" "$(HOME)/.config/opencode/opencode_template.jsonc" && touch "$(HOME)/.config/opencode/.gitignore"

clean:
	@echo "Removing container images"
	@for image in opencode; do \
		if $(CONTAINER_ENGINE) image inspect $$image > /dev/null 2>&1; then \
			echo "Removing $$image"; \
			$(CONTAINER_ENGINE) rmi -f $$image; \
		else \
			echo "Image $$image does not exist, skipping"; \
		fi; \
	done
