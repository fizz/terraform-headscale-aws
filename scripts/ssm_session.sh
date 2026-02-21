#!/usr/bin/env bash
# Start an interactive SSM session on the headscale instance.

set -euo pipefail

PROFILE="${PROFILE:-}"
REGION="${REGION:-us-east-1}"
TAG_NAME="${TAG_NAME:-headscale}"
INSTANCE_ID="${INSTANCE_ID:-}"
AWS_CLI_CONNECT_TIMEOUT="${AWS_CLI_CONNECT_TIMEOUT:-2}"
AWS_CLI_READ_TIMEOUT="${AWS_CLI_READ_TIMEOUT:-30}"

usage() {
    echo "Usage: $0 [--plain|--user USER|--command CMD]" >&2
    echo "Env: PROFILE= REGION=us-east-1 TAG_NAME=headscale INSTANCE_ID=i-... (optional override)" >&2
}

COMMAND=""
PLAIN_SESSION="false"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --plain)
            PLAIN_SESSION="true"
            shift
            ;;
        --user)
            if [[ -n "$COMMAND" ]]; then
                echo "ERROR: Only one of --user/--command may be set." >&2
                exit 1
            fi
            if [[ "${2:-}" == "" ]]; then
                echo "ERROR: --user requires a value." >&2
                exit 1
            fi
            COMMAND="sudo su - $2"
            shift 2
            ;;
        --command)
            if [[ -n "$COMMAND" ]]; then
                echo "ERROR: Only one of --user/--command may be set." >&2
                exit 1
            fi
            if [[ "${2:-}" == "" ]]; then
                echo "ERROR: --command requires a value." >&2
                exit 1
            fi
            COMMAND="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI not found." >&2
    exit 1
fi

if ! command -v session-manager-plugin &> /dev/null; then
    echo "WARNING: session-manager-plugin not found; start-session may fail." >&2
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

profile_args=()
if [[ -n "$PROFILE" ]]; then
    profile_args=(--profile "$PROFILE")
fi

if [[ -z "$COMMAND" && "$PLAIN_SESSION" != "true" ]]; then
    COMMAND='bash -lc "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s ops; else exec /bin/bash -l; fi"'
fi

if [[ -n "$COMMAND" ]]; then
    PARAMS_JSON="$(
        python - <<PY
import json
cmd = ${COMMAND@Q}
print(json.dumps({"command": [cmd]}))
PY
    )"
    aws_cli ssm start-session \
        "${profile_args[@]}" \
        --region "$REGION" \
        --target "$INSTANCE_ID" \
        --document-name "AWS-StartInteractiveCommand" \
        --parameters "$PARAMS_JSON"
else
    aws_cli ssm start-session \
        "${profile_args[@]}" \
        --region "$REGION" \
        --target "$INSTANCE_ID"
fi
