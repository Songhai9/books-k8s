#!/usr/bin/env bash
set -Eeuo pipefail

readonly commit_sha="${1:?Git commit SHA is required}"
readonly image_tag="${2:?image tag is required}"
readonly repository_url="https://github.com/Songhai9/books-k8s.git"

if [[ ! "${commit_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid Git commit SHA." >&2
  exit 2
fi

if [[ ! "${image_tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid container image tag." >&2
  exit 2
fi

deploy_dir="$(mktemp -d /tmp/book-notes-cd.XXXXXX)"
readonly deploy_dir
trap 'rm -rf "${deploy_dir:?}"' EXIT

git -C "${deploy_dir}" init --quiet
git -C "${deploy_dir}" remote add origin "${repository_url}"
git -C "${deploy_dir}" fetch --quiet --depth=1 origin "${commit_sha}"
git -C "${deploy_dir}" checkout --quiet --detach FETCH_HEAD

export KUBECONFIG=/etc/kubernetes/admin.conf
cd "${deploy_dir}"
"${deploy_dir}/scripts/deploy.sh" "${image_tag}"
