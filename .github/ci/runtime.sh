#!/usr/bin/env bash
# Runs a command in the ansible-runtime image (ghcr.io/git-cgallagher/ansible-runtime),
# the pinned toolchain the CI jobs share: ansible-core, ansible-lint, yamllint, Molecule
# with the molecule-git-cgallagher driver, the Python libraries and the third-party
# collections. The image is the pin: these jobs install nothing themselves.
#   RUNTIME_IMAGE=ghcr.io/git-cgallagher/ansible-runtime:X.Y.Z-ci@sha256:... .github/ci/runtime.sh molecule test
#
# Why `docker run` and not a `container:` job: the same wrapper as ansible-collection-isc
# and -orchestration, which mount the checkout at the SAME path and share the runner's
# network for Molecule. Here only lint uses it.
set -euo pipefail
: "${RUNTIME_IMAGE:?set RUNTIME_IMAGE (ansible-test.yml sets it)}"
root=$(git rev-parse --show-toplevel)

# Temporary files go under the checkout too (.cache/ is gitignored), so anything a test
# mounts into `docker run` is on a path the host daemon sees.
tmp="$root/.cache/tmp"
mkdir -p "$tmp"

# The checkout belongs to the runner's user and the image runs as root, so git (which
# ansible-lint uses to list files) needs the checkout marked safe.
exec docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$root:$root" -w "$PWD" -e TMPDIR="$tmp" \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  -e PY_COLORS -e ANSIBLE_FORCE_COLOR -e GITHUB_ACTIONS \
  "$RUNTIME_IMAGE" "$@"
