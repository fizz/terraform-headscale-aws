#!/usr/bin/env bash
# Headscale status via SSM without hardcoded instance IDs.
# Inlines the "all" mode from the former check_headscale.sh wrapper.

set -euo pipefail

MODE="${1:-both}"
FORMAT="${2:-}"

PROFILE="${PROFILE:-}"
REGION="${REGION:-us-east-1}"
TAG_NAME="${TAG_NAME:-headscale}"
INSTANCE_ID="${INSTANCE_ID:-}"
AWS_CLI_CONNECT_TIMEOUT="${AWS_CLI_CONNECT_TIMEOUT:-2}"
AWS_CLI_READ_TIMEOUT="${AWS_CLI_READ_TIMEOUT:-10}"

usage() {
    echo "Usage: $0 [users|nodes|routes|both|all] [--json]" >&2
    echo "Env: PROFILE= REGION=us-east-1 TAG_NAME=headscale INSTANCE_ID=i-... (optional override)" >&2
}

if [[ "$MODE" != "users" && "$MODE" != "nodes" && "$MODE" != "routes" && "$MODE" != "both" && "$MODE" != "all" ]]; then
    usage
    exit 1
fi

JSON_FLAG=""
if [[ "$FORMAT" == "--json" ]]; then
    JSON_FLAG=" -o json"
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

COMMANDS=()
if [[ "$MODE" == "users" || "$MODE" == "both" || "$MODE" == "all" ]]; then
    COMMANDS+=("echo '== Headscale users =='")
    COMMANDS+=("/usr/local/bin/headscale --config /etc/headscale/config.yaml users list${JSON_FLAG}")
    COMMANDS+=("echo")
fi
if [[ "$MODE" == "nodes" || "$MODE" == "both" || "$MODE" == "all" ]]; then
    COMMANDS+=("echo '== Headscale nodes =='")
    COMMANDS+=("/usr/local/bin/headscale --config /etc/headscale/config.yaml nodes list${JSON_FLAG}")
fi
if [[ "$MODE" == "routes" || "$MODE" == "all" ]]; then
    COMMANDS+=("echo")
    COMMANDS+=("echo '== Headscale routes =='")
    COMMANDS+=("/usr/local/bin/headscale --config /etc/headscale/config.yaml routes list${JSON_FLAG}")
    if [[ "$FORMAT" != "--json" ]]; then
        COMMANDS+=("echo")
        COMMANDS+=("echo '== Unapproved routes =='")
        COMMANDS+=("/usr/local/bin/headscale --config /etc/headscale/config.yaml routes list | grep -Ei 'false|pending' || echo 'All routes appear approved'")
    fi
fi

COMMANDS_JOINED="$(printf '%s\n' "${COMMANDS[@]}")"
COMMANDS_JSON=$(COMMANDS="$COMMANDS_JOINED" python - <<'PY'
import json
import os

commands = os.environ.get("COMMANDS", "").splitlines()
commands = [c for c in commands if c.strip() != ""]
print(json.dumps(commands))
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
    echo "Failed to submit SSM command. Check AWS credentials/profile and instance reachability." >&2
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
