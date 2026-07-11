#!/usr/bin/env bash

# Workflow result recording shared by setup and maintenance flows.

record_result() {
  local step status message
  step="$1"
  status="$2"
  message="${3:-}"

  [[ -n "${LINUX_SETUP_RESULT_LOG:-}" ]] || return 0

  message="${message//$'\t'/ }"
  message="${message//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$step" "$status" "$message" >> "$LINUX_SETUP_RESULT_LOG"
}

result_failed_count() {
  local result_log
  result_log="${1:-${LINUX_SETUP_RESULT_LOG:-}}"

  if [[ -z "$result_log" || ! -f "$result_log" ]]; then
    printf '0\n'
    return 0
  fi

  awk -F'\t' '$2 == "failed" {count++} END {print count + 0}' "$result_log"
}
