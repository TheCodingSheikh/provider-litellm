#!/usr/bin/env bash
# Build the upstream Terraform provider from source into a Terraform filesystem
# mirror.
#
# The fixes this Crossplane provider depends on live on an upstream development
# branch that has no release artifact, so the binary cannot be downloaded from
# GitHub releases the way a tagged version would be. Building it here and laying
# the result out as a filesystem mirror lets both halves of the build consume
# it: `terraform providers schema` during code generation, and the runtime
# container image, which already serves its plugins from a mirror.
#
# Usage:
#   build-terraform-provider.sh <repo-url> <ref> <version> <src-dir> <mirror-dir> <platform>...
#
# where <platform> is a Go-style os_arch pair such as linux_amd64.
set -euo pipefail

REPO=${1:?repo url required}
REF=${2:?git ref required}
VERSION=${3:?provider version required}
SRC=${4:?source directory required}
MIRROR=${5:?mirror directory required}
shift 5
PLATFORMS=("$@")
[ ${#PLATFORMS[@]} -gt 0 ] || { echo "at least one platform required" >&2; exit 1; }

BINARY="terraform-provider-litellm_v${VERSION}"
# The mirror is keyed by the registry host the CLI resolves an unqualified
# source against. This build ships OpenTofu, whose default host is
# registry.opentofu.org -- laying the mirror out under registry.terraform.io
# makes OpenTofu report "no available releases match the given constraints".
SOURCE_PATH="registry.opentofu.org/ncecere/litellm"

if [ ! -d "${SRC}/.git" ]; then
  echo "cloning ${REPO} @ ${REF}"
  rm -rf "${SRC}"
  git clone -q -c advice.detachedHead=false --branch "${REF}" "${REPO}" "${SRC}"
else
  echo "fetching ${REF}"
  # Discard any previously applied patches before moving the checkout.
  git -C "${SRC}" reset -q --hard
  git -C "${SRC}" clean -qfd
  # REF may be a branch or a commit; fetch the branch then check out the ref so
  # a pinned SHA stays reproducible even as the branch moves.
  git -C "${SRC}" fetch -q origin issues || true
  git -C "${SRC}" fetch -q origin "${REF}" 2>/dev/null || true
  git -C "${SRC}" checkout -q "${REF}" 2>/dev/null || git -C "${SRC}" checkout -q FETCH_HEAD
fi

SHA=$(git -C "${SRC}" rev-parse HEAD)
echo "upstream ${REF} at ${SHA}"

# Local fixes carried on top of upstream. Each patch is a plain `git diff` and
# is expected to be dropped once the equivalent change lands upstream.
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
PATCHES=()
for patch in "${PATCH_DIR}"/*.patch; do
  [ -f "${patch}" ] || continue
  PATCHES+=("${patch}")
done
if [ ${#PATCHES[@]} -gt 0 ]; then
  for patch in "${PATCHES[@]}"; do
    echo "  applying $(basename "${patch}")"
    git -C "${SRC}" apply --whitespace=nowarn "${patch}"
  done
  # Builds are keyed by upstream SHA plus the patch set, so editing a patch
  # correctly invalidates a previously built binary.
  SHA="${SHA}-$(cat "${PATCHES[@]}" | shasum -a 256 | cut -c1-12)"
fi

for platform in "${PLATFORMS[@]}"; do
  os=${platform%%_*}
  arch=${platform##*_}
  outdir="${MIRROR}/${SOURCE_PATH}/${VERSION}/${os}_${arch}"
  stamp="${outdir}/.source-sha"

  if [ -f "${outdir}/${BINARY}" ] && [ "$(cat "${stamp}" 2>/dev/null || true)" = "${SHA}" ]; then
    echo "  ${platform}: up to date"
    continue
  fi

  echo "  ${platform}: building"
  mkdir -p "${outdir}"
  ( cd "${SRC}" && CGO_ENABLED=0 GOOS="${os}" GOARCH="${arch}" \
      go build -ldflags "-s -w -X main.version=${VERSION}" -o "${outdir}/${BINARY}" ./ )
  chmod +x "${outdir}/${BINARY}"
  echo "${SHA}" >"${stamp}"
done

# A CLI config that pins the provider to the mirror. Terraform will not reach
# out to the registry for it, which matters because this version was never
# published there.
cat >"${MIRROR}/terraformrc" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${MIRROR}"
    include = ["${SOURCE_PATH}"]
  }
  direct {
    exclude = ["${SOURCE_PATH}"]
  }
}
EOF

echo "mirror ready at ${MIRROR} (version ${VERSION})"
