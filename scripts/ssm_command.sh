#!/usr/bin/env bash
# Run an arbitrary command on the headscale instance via SSM.

set -euo pipefail

PROFILE="${PROFILE:-}"
REGION="${REGION:-us-east-1}"
TAG_NAME="${TAG_NAME:-headscale}"
INSTANCE_ID="${INSTANCE_ID:-}"
AWS_CLI_CONNECT_TIMEOUT="${AWS_CLI_CONNECT_TIMEOUT:-2}"
AWS_CLI_READ_TIMEOUT="${AWS_CLI_READ_TIMEOUT:-30}"

usage() {
    echo "Usage: $0 <command>" >&2
    echo "Env: PROFILE= REGION=us-east-1 TAG_NAME=headscale INSTANCE_ID=i-... (optional override)" >&2
}

if [[ "$#" -lt 1 ]]; then
    usage
    exit 1
fi

aws_cli() {
    aws --no-cli-pager \
        --cli-connect-timeout "$AWS_CLI_CONNECT_TIMEOUT" \
        --cli-read-timeout "$AWS_CLI_READ_TIMEOUT" "$@"
}

resolve_instance_id() {
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "$INSTANCE_ID"
        return 0
    fi

    local profile_args=()
    if [[ -n "$PROFILE" ]]; then
        profile_args=(--profile "$PROFILE")
    fi

    local ids
    ids=$(aws_cli ec2 describe-instances \
        "${profile_args[@]}" \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text)

    if [[ -z "$ids" || "$ids" == "None" ]]; then
        echo "No running instances found for tag Name=$TAG_NAME" >&2
        return 1
    fi

    set -- $ids
    if [[ "$#" -gt 1 ]]; then
        echo "Multiple instances found for tag Name=$TAG_NAME, using first: $1" >&2
    fi

    echo "$1"
}

INSTANCE_ID="$(resolve_instance_id)"
COMMAND="$*"

profile_args=()
if [[ -n "$PROFILE" ]]; then
    profile_args=(--profile "$PROFILE")
fi

COMMANDS_JSON=$(COMMAND="$COMMAND" python - <<'PY'
import json
import os

command = os.environ.get("COMMAND", "")
print(json.dumps([command]))
PY
)

COMMAND_ID=$(aws_cli ssm send-command \
    "${profile_args[@]}" \
    --region "$REGION" \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --parameters "commands=$COMMANDS_JSON" \
    --query "Command.CommandId" \
    --output text)

if [[ -z "$COMMAND_ID" || "$COMMAND_ID" == "None" ]]; then
    echo "Failed to submit SSM command." >&2
    exit 1
fi

STATUS=""
while :; do
    STATUS=$(aws_cli ssm get-command-invocation \
        "${profile_args[@]}" \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "Status" \
        --output text 2>/dev/null || true)
    case "$STATUS" in
        Success|Cancelled|Failed|TimedOut|Cancelling) break ;;
        "") sleep 1 ;;
        *) sleep 1 ;;
    esac
done

STDOUT=$(aws_cli ssm get-command-invocation \
    "${profile_args[@]}" \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" \
    --output text)
STDERR=$(aws_cli ssm get-command-invocation \
    "${profile_args[@]}" \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardErrorContent" \
    --output text)

if [[ -n "$STDOUT" && "$STDOUT" != "None" ]]; then
    printf "%s\n" "$STDOUT"
fi
if [[ -n "$STDERR" && "$STDERR" != "None" ]]; then
    printf "%s\n" "$STDERR" >&2
fi

if [[ "$STATUS" != "Success" ]]; then
    echo "SSM command failed with status: $STATUS" >&2
    exit 1
fi
