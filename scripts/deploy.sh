#!/usr/bin/env bash
set -Eeuo pipefail

readonly image_tag="${1:?image tag is required}"
readonly release_name="book-notes"
readonly namespace="book-notes"
readonly chart_path="charts/book-notes"

if [[ ! "${image_tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid container image tag." >&2
  exit 2
fi

for command in curl helm kubectl; do
  command -v "${command}" >/dev/null
done

helm upgrade --install "${release_name}" "${chart_path}" \
  --namespace "${namespace}" \
  --set-string "app.image.tag=${image_tag}" \
  --server-side=true \
  --wait=watcher \
  --timeout 10m \
  --history-max 10

kubectl --namespace "${namespace}" rollout status \
  statefulset/book-notes-postgres --timeout=5m
kubectl --namespace "${namespace}" rollout status \
  deployment/book-notes --timeout=5m

gateway_programmed="$(
  kubectl --namespace "${namespace}" get gateway book-notes \
    -o 'jsonpath={.status.conditions[?(@.type=="Programmed")].status}'
)"
route_accepted="$(
  kubectl --namespace "${namespace}" get httproute book-notes \
    -o 'jsonpath={.status.parents[0].conditions[?(@.type=="Accepted")].status}'
)"
refs_resolved="$(
  kubectl --namespace "${namespace}" get httproute book-notes \
    -o 'jsonpath={.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'
)"

test "${gateway_programmed}" = "True"
test "${route_accepted}" = "True"
test "${refs_resolved}" = "True"

worker_ip="$(
  kubectl get node books-dev-k8s-worker \
    -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}'
)"
readonly worker_ip

curl --fail --silent --show-error --retry 12 --retry-all-errors \
  --retry-delay 5 "http://${worker_ip}:30080/health"
printf '\n'
curl --fail --silent --show-error --retry 12 --retry-all-errors \
  --retry-delay 5 "http://${worker_ip}:30080/ready"
printf '\n'
curl --fail --silent --show-error --output /dev/null \
  --write-out 'homepage_status=%{http_code}\n' \
  "http://${worker_ip}:30080/"

helm status "${release_name}" --namespace "${namespace}"
