#!/usr/bin/env bash
# start_reading.sh — Run weread-selenium-cli once, lock-protected, non-blocking.
# Usage:
#   start_reading.sh [trigger]      # blocks current shell, but caller usually
#                                   # invokes this with `&` or via Flask thread.
set -uo pipefail

TRIGGER="${1:-manual}"
DATA_DIR="${WEREAD_DATA_DIR:-/data/.weread}"
LOG_FILE="${DATA_DIR}/app.log"
LOCK_FILE="${DATA_DIR}/run.lock"
PID_FILE="${DATA_DIR}/run.pid"
STATE_FILE="${DATA_DIR}/last_run.json"
SCREENSHOT_KEEP="${SCREENSHOT_KEEP:-10}"
BARK_URL="${BARK_URL:-https://api.day.app}"
SPACE_URL="${SPACE_URL:-${SPACE_HOST:-https://smith6666-weread-challenge.hf.space}}"

mkdir -p "$DATA_DIR"
touch "$LOG_FILE"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[start_reading %s] %s\n' "$(ts)" "$*" >>"$LOG_FILE"; }
urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

notify_bark() {
    local title="$1"
    local body="$2"
    local endpoint="${BARK_ENDPOINT:-}"
    local title_enc body_enc

    if [[ -z "$endpoint" && -n "${BARK_KEY:-}" ]]; then
        endpoint="${BARK_URL%/}/${BARK_KEY}"
    fi
    [[ -z "$endpoint" ]] && return 0

    endpoint="${endpoint%/}"
    title_enc="$(urlencode "$title")"
    body_enc="$(urlencode "$body")"

    if curl -fsS --get "${endpoint}/${title_enc}/${body_enc}" \
        --data-urlencode "group=weread-challenge" \
        --data-urlencode "url=${SPACE_URL}/" \
        >/dev/null 2>&1; then
        log "Bark notification sent"
    else
        log "Bark notification failed"
    fi
}

notify_telegram() {
    local title="$1"
    local body="$2"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

    if curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${title}
${body}

${SPACE_URL}/" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null 2>&1; then
        log "Telegram notification sent"
    else
        log "Telegram notification failed"
    fi
}

notify_webhook() {
    local status="$1"
    local title="$2"
    local body="$3"
    [[ -z "${WEBHOOK_URL:-}" ]] && return 0

    if curl -fsS -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"${title}\",\"body\":\"${body}\",\"status\":\"${status}\",\"space_url\":\"${SPACE_URL}/\"}" \
        >/dev/null 2>&1; then
        log "Webhook notification sent"
    else
        log "Webhook notification failed"
    fi
}

notify_all() {
    local status="$1"
    local exit_code="$2"
    local title body

    if [[ "$status" == "completed" ]]; then
        title="WeRead Challenge completed"
        body="trigger=${TRIGGER}, duration=${WEREAD_DURATION:-68}m, ended_at=${ENDED_AT}"
    else
        title="WeRead Challenge failed"
        body="trigger=${TRIGGER}, exit_code=${exit_code}, ended_at=${ENDED_AT}"
    fi

    notify_bark "$title" "$body"
    notify_telegram "$title" "$body"
    notify_webhook "$status" "$title" "$body"
}

write_state() {
    # write_state <status> <extra-json-fields>
    local status="$1"
    local extra="${2:-}"
    local started_at="${STARTED_AT:-}"
    local ended_at="${ENDED_AT:-}"
    local exit_code="${EXIT_CODE:-}"
    {
        printf '{'
        printf '"status":"%s"' "$status"
        printf ',"trigger":"%s"' "$TRIGGER"
        [[ -n "$started_at" ]] && printf ',"started_at":"%s"' "$started_at"
        [[ -n "$ended_at"   ]] && printf ',"ended_at":"%s"' "$ended_at"
        [[ -n "$exit_code"  ]] && printf ',"exit_code":%s' "$exit_code"
        printf ',"duration_minutes":%s' "${WEREAD_DURATION:-68}"
        [[ -n "$extra" ]] && printf ',%s' "$extra"
        printf '}\n'
    } >"$STATE_FILE"
}

prune_screenshots() {
    # Keep only the most recent $SCREENSHOT_KEEP screenshot-*.png files.
    local count lc
    shopt -s nullglob
    local screenshots=("$DATA_DIR"/screenshot-*.png)
    local selenium_logs=("$DATA_DIR"/selenium-logs-*.log)
    count=${#screenshots[@]}
    if [[ "$count" -gt "${SCREENSHOT_KEEP:-10}" ]]; then
        ls -1t "$DATA_DIR"/screenshot-*.png 2>/dev/null \
            | tail -n +"$((SCREENSHOT_KEEP + 1))" \
            | xargs -r rm -f
        log "pruned screenshots (kept $SCREENSHOT_KEEP)"
    fi
    # Cap selenium-logs-*.log to 5 newest as well.
    lc=${#selenium_logs[@]}
    if [[ "$lc" -gt 5 ]]; then
        ls -1t "$DATA_DIR"/selenium-logs-*.log 2>/dev/null \
            | tail -n +6 \
            | xargs -r rm -f
    fi
    shopt -u nullglob
}

# Acquire exclusive lock, non-blocking. fd 9 is closed automatically on exit.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another reading run is in progress (lock held); skipping trigger=$TRIGGER"
    exit 0
fi

STARTED_AT="$(ts)"
echo $$ >"$PID_FILE"
write_state "running"
log "▶ starting weread-selenium-cli run (trigger=$TRIGGER, duration=${WEREAD_DURATION:-68}m)"

set +e
weread-selenium-cli run >>"$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

ENDED_AT="$(ts)"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    write_state "completed"
    log "✓ run finished cleanly"
    notify_all "completed" "$EXIT_CODE"
else
    write_state "failed"
    log "✗ run exited with code $EXIT_CODE"
    notify_all "failed" "$EXIT_CODE"
fi

rm -f "$PID_FILE"
prune_screenshots
exit "$EXIT_CODE"
