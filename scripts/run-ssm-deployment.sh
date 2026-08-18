#!/usr/bin/env bash
set -Eeuo pipefail

readonly instance_id="${1:?control-plane instance ID is required}"
readonly commit_sha="${2:?Git commit SHA is required}"
readonly image_tag="${3:?image tag is required}"
readonly aws_region="${AWS_REGION:?AWS_REGION is required}"

if [[ ! "${instance_id}" =~ ^i-[0-9a-f]{8,17}$ ]]; then
  echo "Invalid EC2 instance ID." >&2
  exit 2
fi

if [[ ! "${commit_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid Git commit SHA." >&2
  exit 2
fi

if [[ ! "${image_tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid container image tag." >&2
  exit 2
fi

for command in aws base64 jq; do
  command -v "${command}" >/dev/null
done

readonly bootstrap_base64="$(base64 --wrap=0 scripts/ssm-bootstrap.sh)"
readonly remote_command="printf '%s' '${bootstrap_base64}' | base64 --decode | bash -s -- '${commit_sha}' '${image_tag}'"
readonly parameters="$(jq --compact-output --null-input --arg command "${remote_command}" '{commands: [$command]}')"

command_id="$(
  aws ssm send-command \
    --region "${aws_region}" \
    --instance-ids "${instance_id}" \
    --document-name AWS-RunShellScript \
    --comment "Deploy books-k8s ${commit_sha}" \
    --timeout-seconds 900 \
    --parameters "${parameters}" \
    --query 'Command.CommandId' \
    --output text
)"
readonly command_id

echo "SSM command: ${command_id}"

status=""
for _ in $(seq 1 180); do
  status="$(
    aws ssm get-command-invocation \
      --region "${aws_region}" \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query 'Status' \
      --output text 2>/dev/null || true
  )"

  case "${status}" in
    Success | Cancelled | TimedOut | Failed | Cancelling)
      break
      ;;
    Pending | InProgress | Delayed | "")
      sleep 5
      ;;
    *)
      echo "Unexpected SSM status: ${status}" >&2
      exit 1
      ;;
  esac
done

invocation="$(
  aws ssm get-command-invocation \
    --region "${aws_region}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --output json
)"
readonly invocation

echo "$(jq --raw-output '.StandardOutputContent' <<<"${invocation}")"

if [[ "${status}" != "Success" ]]; then
  echo "$(jq --raw-output '.StandardErrorContent' <<<"${invocation}")" >&2
  echo "Deployment failed with SSM status ${status}." >&2
  exit 1
fi
