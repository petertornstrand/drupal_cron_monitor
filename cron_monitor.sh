#!/usr/bin/env bash
# cron_monitor.sh
# Checks Drupal's last cron run time and, if older than a threshold, creates a ticket via CodebaseHQ API.
# Place this script in the project root. Make it executable: chmod +x ./cron_monitor.sh
# You can add this to crontab, e.g., run every hour.
#
# Environment variables (all optional; defaults shown in parentheses):
# - CB_ACCOUNT ("your-account")
#     CodebaseHQ account subdomain (the part before .codebasehq.com).
#     Example: export CB_ACCOUNT=mycompany
# - CB_PROJECT_PERMALINK ("your-project")
#     CodebaseHQ project permalink/identifier.
#     Example: export CB_PROJECT_PERMALINK=website
# - CB_USERNAME ("your-username")
#     CodebaseHQ username for API authentication.
#     Example: export CB_USERNAME=jane.smith
# - CB_API_KEY ("your-api-key")
#     CodebaseHQ API access key paired with CB_USERNAME for Basic Auth.
#     Example: export CB_API_KEY=xxxxxxxxxxxxxxxx
# - CB_API_BASE ("https://api3.codebasehq.com")
#     Base URL for the CodebaseHQ v3 API. Change if your account uses a different API host.
#
# Ticket parameters
# - CB_TICKET_PRIORITY ("3")
#     Ticket priority number. Common range is 1 (lowest) to 5 (highest).
# - CB_TICKET_STATUS ("new")
#     Initial ticket status. Adjust to values supported by your workflow (e.g., new, open).
# - CB_TICKET_TYPE ("bug")
#     Ticket type/category, e.g., bug, feature, support.
#
# Monitoring behavior
# - CB_THRESHOLD_SECONDS (14400)
#     Age threshold in seconds for considering cron stale (default 4 hours).
# - CB_SITE_NAME (empty)
#     Optional site display name to include in the ticket; defaults to system hostname if empty.
# - CB_MULTISITE_HOST (empty)
#     Optional: Drupal multisite host/site URI to target a specific site. When set, drush is invoked as:
#       drush -l <CB_MULTISITE_HOST> state:get system.cron_last
#     Works with or without DDEV (e.g., "ddev drush -l <host> ...").
#
# State/duplicate suppression
# - CB_STATE_DIR (".monitor_state")
#     Directory used to store the last notification timestamp.
# - CB_STATE_FILE ("$STATE_DIR/cron_monitor.last_sent")
#     File path that records the last time a ticket was sent to avoid duplicates for the same stale period.
#
# Runtime toggles
# - CB_VERBOSE (1)
#     1 = verbose logs to stdout; 0 = quiet.
# - CB_DRY_RUN (0)
#     1 = do not perform the API call; only log what would happen.
#
# Notes
# - Drush command resolution: prefers "ddev drush" when DDEV is available; otherwise tries ./vendor/bin/drush, then system drush.
# - The script uses a simple state file to prevent duplicate tickets while the same stale window persists.
#
# Examples
#   # One-off dry run with explicit settings
#   CB_ACCOUNT=myacct CB_PROJECT_PERMALINK=myproj CB_USERNAME=jane CB_API_KEY=abc123 CB_DRY_RUN=1 ./cron_monitor.sh
#
#   # Persistent environment setup
#   export CB_ACCOUNT=myacct
#   export CB_PROJECT_PERMALINK=myproj
#   export CB_USERNAME=jane
#   export CB_API_KEY=abc123
#   export CB_THRESHOLD_SECONDS=21600   # 6 hours
#   export CB_TICKET_PRIORITY=4
#   ./cron_monitor.sh
#
#   # Quiet run from crontab (every hour on the hour)
#   0 * * * * cd /path/to/project && CB_VERBOSE=0 ./cron_monitor.sh >/dev/null 2>&1

set -euo pipefail

# ========================
# Configuration
# ========================
# All configuration values can be provided via environment variables. The values below are defaults.
# CodebaseHQ settings
CB_ACCOUNT=${CB_ACCOUNT:-"your-account"}                 # Your CodebaseHQ account subdomain (before .codebasehq.com)
CB_PROJECT_PERMALINK=${CB_PROJECT_PERMALINK:-"your-project"} # The project permalink/identifier in CodebaseHQ
CB_USERNAME=${CB_USERNAME:-"your-username"}               # Your CodebaseHQ username (or account email/username)
CB_API_KEY=${CB_API_KEY:-"your-api-key"}                   # Your CodebaseHQ API access key
CB_API_BASE=${CB_API_BASE:-"https://api3.codebasehq.com"}  # Base API URL (default for CodebaseHQ v3)

# Ticket defaults
TICKET_PRIORITY=${CB_TICKET_PRIORITY:-"3"}         # 1 (lowest) to 5 (highest)
TICKET_STATUS=${CB_TICKET_STATUS:-"new"}           # e.g., new, open, etc.
TICKET_TYPE=${CB_TICKET_TYPE:-"bug"}               # e.g., bug, feature, support

# Threshold in seconds (4 hours = 14400 seconds)
THRESHOLD_SECONDS=${CB_THRESHOLD_SECONDS:-14400}

# Optional: Site name to show in the ticket; if empty, hostname will be used
SITE_NAME=${CB_SITE_NAME:-}

# Optional: Drupal multisite host to scope drush (site URI)
MULTISITE_HOST=${CB_MULTISITE_HOST:-}

# State file to avoid duplicate tickets while the issue persists
STATE_DIR=${CB_STATE_DIR:-".monitor_state"}
STATE_FILE=${CB_STATE_FILE:-"$STATE_DIR/cron_monitor.last_sent"}

# Verbosity and dry-run controls
VERBOSE=${CB_VERBOSE:-1}              # 1 = verbose, 0 = quiet
DRY_RUN=${CB_DRY_RUN:-0}              # 1 = do not actually create a ticket

# ========================
# Helpers
# ========================
log() {
  if [[ "${VERBOSE}" == "1" ]]; then
    echo "[cron_monitor] $*"
  fi
}

err() {
  echo "[cron_monitor][ERROR] $*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Determine how to run drush
resolve_drush() {
  if have_cmd ddev; then
    echo "ddev drush"
    return 0
  fi
  if [[ -x "./vendor/bin/drush" ]]; then
    echo "./vendor/bin/drush"
    return 0
  fi
  if have_cmd drush; then
    echo "drush"
    return 0
  fi
  return 1
}

# Reads the Drupal state variable system.cron_last as epoch seconds
get_cron_last() {
  local drush_cmd
  if ! drush_cmd=$(resolve_drush); then
    err "Could not find drush. Ensure DDEV is installed (for 'ddev drush') or ./vendor/bin/drush exists."
    return 2
  fi

  # Using state:get which returns the raw value
  local value
  local site_flag=""
  if [[ -n "${MULTISITE_HOST:-}" ]]; then
    site_flag="-l ${MULTISITE_HOST}"
  fi
  if ! value=$($drush_cmd $site_flag state:get system.cron_last 2>/dev/null | tr -d '\r'); then
    err "Failed to get system.cron_last via drush."
    return 3
  fi

  # Trim whitespace
  value=$(echo -n "$value" | awk '{$1=$1};1')

  if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
    # Some sites may have never run cron; treat as 0
    echo 0
  else
    echo "$value"
  fi
}

# Create CodebaseHQ ticket
create_codebase_ticket() {
  local summary="$1"
  local description="$2"

  if [[ -z "$CB_PROJECT_PERMALINK" || -z "$CB_USERNAME" || -z "$CB_API_KEY" ]]; then
    err "CodebaseHQ credentials/config are not fully set. Please set environment variables (CB_PROJECT_PERMALINK, CB_USERNAME, CB_API_KEY) or edit the script defaults."
    return 4
  fi

  # Endpoint (XML payload per CodebaseHQ API v3)
  # Note: Correct endpoint does not include account or 'projects' segment; many accounts require a .xml suffix for routing.
  local base_url="${CB_API_BASE}/${CB_PROJECT_PERMALINK}/tickets"
  local url_xml="${base_url}.xml"
  local url_noext="${base_url}"

  # Build XML payload
  # Note: Some fields like <priority>, <status>, <ticket-type> may vary by workflow.
  # Remove or adjust if your account uses different values.
  local xml
  xml=$(cat <<XML
<ticket>
  <summary>${summary}</summary>
  <description>${description}</description>
  <priority>${TICKET_PRIORITY}</priority>
  <status>${TICKET_STATUS}</status>
  <ticket-type>${TICKET_TYPE}</ticket-type>
</ticket>
XML
)

  log "Creating CodebaseHQ ticket at ${url_xml}"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1 — skipping API call. Payload would be:\n${xml}"
    return 0
  fi

  # Perform API request using basic auth (username:api_key)
  local http_code
  http_code=$(curl -sS -o /tmp/cron_monitor_cb_response.$$ -w "%{http_code}" \
    -u "${CB_USERNAME}:${CB_API_KEY}" \
    -H "Content-Type: application/xml" \
    -H "Accept: application/xml" \
    -X POST \
    --data-binary "${xml}" \
    "${url_xml}" || true)

  # If 404, retry without .xml (some setups allow content negotiation by header)
  if [[ "$http_code" == "404" ]]; then
    log "First attempt returned 404, retrying without .xml at ${url_noext}"
    http_code=$(curl -sS -o /tmp/cron_monitor_cb_response.$$ -w "%{http_code}" \
      -u "${CB_USERNAME}:${CB_API_KEY}" \
      -H "Content-Type: application/xml" \
      -H "Accept: application/xml" \
      -X POST \
      --data-binary "${xml}" \
      "${url_noext}" || true)
  fi

  if [[ "$http_code" =~ ^20[01]$ ]]; then
    log "Ticket created successfully (HTTP ${http_code})."
    return 0
  else
    err "Failed to create ticket (HTTP ${http_code}). Response:"
    cat /tmp/cron_monitor_cb_response.$$ >&2 || true
    return 5
  fi
}

# Ensure state dir exists
mkdir -p "$STATE_DIR"

# ========================
# Main
# ========================
now=$(date +%s)
cron_last=$(get_cron_last || echo 0)

if [[ -z "$cron_last" || ! "$cron_last" =~ ^[0-9]+$ ]]; then
  cron_last=0
fi

age=$(( now - cron_last ))

# Build context strings
host=$(hostname || echo "unknown-host")
site_display=${SITE_NAME:-$host}
last_human=$(date -d @${cron_last} "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || date -r ${cron_last} "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "${cron_last}")
now_human=$(date "+%Y-%m-%d %H:%M:%S %Z")

log "Current time: ${now_human} (${now})"
log "Cron last run: ${last_human} (${cron_last})"
log "Age (seconds): ${age}; threshold: ${THRESHOLD_SECONDS}"

if (( age <= THRESHOLD_SECONDS )); then
  log "Cron is within threshold; nothing to do."
  exit 0
fi

# Avoid duplicate tickets: read last sent timestamp
last_sent=0
if [[ -f "$STATE_FILE" ]]; then
  last_sent=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ -z "$last_sent" || ! "$last_sent" =~ ^[0-9]+$ ]]; then
    last_sent=0
  fi
fi

# If we've already sent a ticket for this stale window (i.e., last_sent >= cron_last), skip
if (( last_sent >= cron_last )); then
  log "A ticket was already sent for this stale period (last_sent=${last_sent}). Skipping."
  exit 0
fi

summary="Cron has not run for over $(( THRESHOLD_SECONDS / 3600 )) hours on ${site_display}"
description=$(cat <<DESC
Automatic alert from cron_monitor.sh

Site: ${site_display}
Host: ${host}
Environment Path: $(pwd)

Last cron run: ${last_human} (epoch ${cron_last})
Current time:  ${now_human} (epoch ${now})
Age: ${age} seconds (~$(( age / 3600 )) hours)

Action: Please investigate why Drupal cron is not running.
DESC
)

if create_codebase_ticket "$summary" "$description"; then
  echo "$now" > "$STATE_FILE"
  log "Recorded last_sent=${now} in ${STATE_FILE}"
  exit 0
else
  err "Ticket creation failed. Not updating ${STATE_FILE}."
  exit 1
fi
