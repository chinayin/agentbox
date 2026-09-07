# Image tags default to `dev`; release versions come from git tags via CI (VERSION=X.Y.Z).
#   make image PLATFORM=linux/amd64 UID=1001 GID=1001
#   make image BUILD_ARGS='--build-arg HTTPS_PROXY=http://proxy:port'   # build host behind a proxy
#   MISE=/path/to/mise make lock                                        # mise >= mise.toml min_version

IMAGE      ?= agentbox
VERSION    ?= dev
PLATFORM   ?=
UID        ?= 1000
GID        ?= 1000
BUILD_ARGS ?=
MISE       ?= mise

BUILD = docker build $(if $(PLATFORM),--platform $(PLATFORM)) \
        --build-arg AGENTBOX_VERSION=$(VERSION) --build-arg AGENT_UID=$(UID) --build-arg AGENT_GID=$(GID) $(BUILD_ARGS)
# MISE_ENV=pi loads mise.toml + mise.pi.toml and writes both lock files in one run.
LOCK = MISE_ENV=pi MISE_TRUSTED_CONFIG_PATHS=$(CURDIR) $(MISE) lock

.PHONY: help image image-claude image-pi lock lock-refresh test lint smoke check

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'

image: image-claude image-pi ## Build both images

image-claude: ## Build agentbox:<VERSION>
	$(BUILD) --target agentbox -t $(IMAGE):$(VERSION) .

image-pi: ## Build agentbox:<VERSION>-pi
	$(BUILD) --target agentbox-pi -t $(IMAGE):$(VERSION)-pi .

lock: ## Bump every tool to upstream latest and rewrite lock files (network)
	$(LOCK) --bump

lock-refresh: ## Re-resolve URLs/checksums for the locked versions without bumping (network)
	$(LOCK)

test: ## Self-test, no docker, no network
	bash scripts/test.sh

lint: ## shellcheck, warnings block
	@command -v shellcheck >/dev/null || { echo "error: shellcheck required (brew install shellcheck / apt-get install shellcheck)" >&2; exit 2; }
	shellcheck -x -S warning entrypoint.sh scripts/*.sh .claude/skills/*/scripts/*.sh

smoke: ## Runtime smoke test against built images (docker)
	bash scripts/smoke.sh --image $(IMAGE):$(VERSION) --pi-image $(IMAGE):$(VERSION)-pi $(if $(PLATFORM),--platform $(PLATFORM))

check: test lint ## Pre-commit gate, no docker
