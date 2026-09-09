# One build definition for the Makefile, ci.yml and release.yml, so a target, platform or build arg
# is written once. Stage names here must match the Dockerfile; test.sh gates that.
#
# Always pass -f: with no -f, bake also auto-loads docker-compose.yaml, whose env_file points at a
# gitignored path, and the whole invocation fails on a clean clone.
#
#   docker buildx bake -f docker-bake.hcl --load    # both images, native, agentbox:dev
#   docker buildx bake -f docker-bake.hcl --load claude          # one target
#   VERSION=1.2.3 PLATFORMS=linux/amd64,linux/arm64 \
#     docker buildx bake -f docker-bake.hcl --push                # multi-arch release
#
# Every variable is read from the environment, which is how the Makefile and the workflows drive it.

variable "IMAGE" { default = "agentbox" }

# The version is the only source of the image tag and of /etc/agentbox/version inside the image.
variable "VERSION" { default = "dev" }

# Empty means the builder's native platform. Comma-separated for multi-arch; --load cannot take
# more than one, so multi-arch builds must --push.
variable "PLATFORMS" { default = "" }

# Only set when the host owner is not 1000; empty falls through to the Dockerfile defaults.
variable "AGENT_UID" { default = "" }
variable "AGENT_GID" { default = "" }

# Build cache. Empty disables it entirely -- that is the state while the packages are private,
# because GitHub only bills private packages and the cache would silently blow the quota.
# CACHE_TO is set on the claude target alone: both targets share the whole toolchain, so one writer
# stores every expensive layer once, with no concurrent writes racing for the same registry ref.
variable "CACHE_FROM" { default = "" }
variable "CACHE_TO" { default = "" }

# Proxy for a build host without direct upstream access (docs/CN_MIRRORS.md). They become Docker's
# predefined build args, which need no ARG line, never land in the image, and are excluded from the
# cache key, so a proxied build and a direct one share layers.
#
# The BUILD_ prefix is not cosmetic. Every bake variable is populated from the environment, so a
# variable named HTTP_PROXY silently absorbs the developer's shell proxy -- and a loopback address
# like 127.0.0.1:7890 means the build container itself, so every download in the build hangs or
# fails. Verified on a Clash setup. Naming them BUILD_* makes the forward explicit and opt-in.
variable "BUILD_HTTP_PROXY" { default = "" }
variable "BUILD_HTTPS_PROXY" { default = "" }
variable "BUILD_NO_PROXY" { default = "" }

group "default" {
  targets = ["claude", "pi"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = PLATFORMS == "" ? [] : split(",", PLATFORMS)

  # null drops the key entirely. An empty string would not: it would override the Dockerfile's
  # ARG default with "", and `useradd -u ""` fails the build.
  args = {
    AGENTBOX_VERSION = VERSION
    AGENT_UID        = AGENT_UID == "" ? null : AGENT_UID
    AGENT_GID        = AGENT_GID == "" ? null : AGENT_GID
    HTTP_PROXY       = BUILD_HTTP_PROXY == "" ? null : BUILD_HTTP_PROXY
    HTTPS_PROXY      = BUILD_HTTPS_PROXY == "" ? null : BUILD_HTTPS_PROXY
    NO_PROXY         = BUILD_NO_PROXY == "" ? null : BUILD_NO_PROXY
  }

  cache-from = CACHE_FROM == "" ? [] : ["type=registry,ref=${CACHE_FROM}"]
}

target "claude" {
  inherits = ["_common"]
  target   = "agentbox-claude"
  tags     = ["${IMAGE}:${VERSION}"]

  # ignore-error: the images are already built and pushed by the time the cache exports, so a
  # registry hiccup or a quota refusal must warn, never fail the release.
  cache-to = CACHE_TO == "" ? [] : ["type=registry,ref=${CACHE_TO},mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true"]
}

target "pi" {
  inherits = ["_common"]
  target   = "agentbox-pi"
  tags     = ["${IMAGE}:${VERSION}-pi"]
}
