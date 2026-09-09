# Image tags default to `dev`; release versions come from git tags via CI (VERSION=X.Y.Z).
#   make image PLATFORM=linux/arm64                                 # one platform, into the local daemon
#   make image AGENT_UID=1001 AGENT_GID=1001                        # only when the host owner is not 1000
#   make image BUILD_HTTPS_PROXY=http://proxy:port BUILD_HTTP_PROXY=http://proxy:port  # proxied build host
#   make image BAKE_ARGS='--set *.args.FOO=bar'                     # anything else bake can set
#   MISE=/path/to/mise make lock                                    # mise >= mise.toml min_version
#
# Targets, platforms and build args live in docker-bake.hcl, shared with ci.yml and release.yml so
# no two of them can drift. Recipes are silent; `make -n <target>` prints the resolved command.

IMAGE       ?= agentbox
VERSION     ?= dev
PLATFORM    ?=
AGENT_UID   ?=
AGENT_GID   ?=
BUILD_HTTP_PROXY  ?=
BUILD_HTTPS_PROXY ?=
BUILD_NO_PROXY    ?=
BAKE_ARGS   ?=
MISE        ?= mise

# -f is mandatory: with no -f, bake also auto-loads docker-compose.yaml, whose env_file points at a
# gitignored path, and the invocation fails on a clean clone. --load puts the result in the local
# daemon, which `make smoke` needs; it accepts a single platform only, so releases --push instead.
# Proxy variables carry a BUILD_ prefix on purpose: make imports the environment, and bake reads its
# variables from it too, so a plain HTTPS_PROXY would silently forward the developer's shell proxy
# into the build -- where a loopback address points at the build container, not the host.
BAKE = IMAGE=$(IMAGE) VERSION=$(VERSION) PLATFORMS=$(PLATFORM) \
       AGENT_UID=$(AGENT_UID) AGENT_GID=$(AGENT_GID) \
       $(if $(BUILD_HTTP_PROXY),BUILD_HTTP_PROXY=$(BUILD_HTTP_PROXY)) \
       $(if $(BUILD_HTTPS_PROXY),BUILD_HTTPS_PROXY=$(BUILD_HTTPS_PROXY)) \
       $(if $(BUILD_NO_PROXY),BUILD_NO_PROXY=$(BUILD_NO_PROXY)) \
       docker buildx bake -f docker-bake.hcl --load $(BAKE_ARGS)

# MISE_ENV=claude,pi loads mise.toml plus every agent overlay and writes all lock files in one run.
LOCK = MISE_ENV=claude,pi MISE_TRUSTED_CONFIG_PATHS=$(CURDIR) $(MISE) lock

.PHONY: help image image-claude image-pi lock lock-refresh test lint smoke check

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'

image: ## Build both images (agentbox:<VERSION> and -pi), in parallel
	@$(BAKE)

image-claude: ## Build agentbox:<VERSION> (Claude Code)
	@$(BAKE) claude

image-pi: ## Build agentbox:<VERSION>-pi (pi)
	@$(BAKE) pi

lock: ## Bump every tool to upstream latest and rewrite lock files (network)
	@$(LOCK) --bump

lock-refresh: ## Re-resolve URLs/checksums for the locked versions without bumping (network)
	@$(LOCK)

test: ## Self-test, no docker, no network
	@bash scripts/test.sh

lint: ## shellcheck, warnings block
	@command -v shellcheck >/dev/null || { echo "Error: shellcheck required (brew install shellcheck / apt-get install shellcheck)" >&2; exit 2; }
	@shellcheck -x -S warning entrypoint.sh scripts/*.sh .claude/skills/*/scripts/*.sh

smoke: ## Runtime smoke test against built images (docker)
	@bash scripts/smoke.sh --image $(IMAGE):$(VERSION) --pi-image $(IMAGE):$(VERSION)-pi $(if $(PLATFORM),--platform $(PLATFORM))

check: test lint ## Pre-commit gate, no docker
