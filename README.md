# Drupal Cron Monitor (cron_monitor.sh)

This repository contains a small Bash script that checks when Drupal last ran cron and, if it’s older than a configurable threshold, creates a ticket in CodebaseHQ.

The script is designed to:
- Detect and use Drush in common environments (prefers `ddev drush`, then `./vendor/bin/drush`, then system `drush`).
- Work with Drupal multisite (optional `-l` site URI).
- Avoid duplicate tickets for the same stale period by keeping a simple state file.
- Be configured entirely through environment variables prefixed with `CB_`.


## Files
- `cron_monitor.sh` — main script. Make it executable and run it from the project root.
- `monitor.sh` — example runner that sets variables inline and runs the monitor (optional).


## Prerequisites
- Bash (script uses `set -euo pipefail`).
- Drush available via one of:
  - `ddev drush` (if you use DDEV), or
  - `./vendor/bin/drush` (installed via Composer), or
  - `drush` on your PATH.
- curl (for the CodebaseHQ API).


## Installation
1. Place `cron_monitor.sh` in the project root (already in this repository).
2. Make it executable:
   chmod +x ./cron_monitor.sh


## Configuration (Environment Variables)
All variables are optional and have sensible defaults unless noted. Prefix: `CB_`.

Connection / API
- `CB_PROJECT_PERMALINK` (required for ticket creation)
  - CodebaseHQ project permalink/identifier.
  - Example: `export CB_PROJECT_PERMALINK=website`
- `CB_USERNAME` (required for ticket creation)
  - CodebaseHQ username. If your account requires the account scope, use the format `account/username`.
  - Example: `export CB_USERNAME=happiness/petertornstrand`
- `CB_API_KEY` (required for ticket creation)
  - CodebaseHQ API access key.
  - Example: `export CB_API_KEY=xxxxxxxxxxxxxxxx`
- `CB_API_BASE` (default: `https://api3.codebasehq.com`)
  - Base URL for the CodebaseHQ v3 API.
- `CB_ACCOUNT`
  - Kept for compatibility in comments/examples but not required for the ticket creation endpoint used.

Ticket Parameters
- `CB_TICKET_PRIORITY` (default: `3`)
  - Priority number, usually 1 (lowest) to 5 (highest).
- `CB_TICKET_STATUS` (default: `new`)
  - Initial ticket status (e.g., `new`, `open`).
- `CB_TICKET_TYPE` (default: `bug`)
  - Ticket type/category (e.g., `bug`, `feature`, `support`).

Monitoring Behavior
- `CB_THRESHOLD_SECONDS` (default: `14400`)
  - Age threshold in seconds for considering cron stale (4 hours by default).
- `CB_SITE_NAME` (no default)
  - Optional display name to include in the ticket; if empty, the system hostname is used.
- `CB_MULTISITE_HOST` (no default)
  - Drupal multisite host/site URI. When set, Drush is invoked as `drush -l <CB_MULTISITE_HOST> state:get system.cron_last`. Works with or without DDEV.

State / Duplicate Suppression
- `CB_STATE_DIR` (default: `.monitor_state`)
  - Directory used to store the last notification timestamp.
- `CB_STATE_FILE` (default: `$CB_STATE_DIR/cron_monitor.last_sent`)
  - File path recording the last time a ticket was sent to prevent duplicates for the same stale window.

Runtime Toggles
- `CB_VERBOSE` (default: `1`)
  - Set `0` for quiet runs; `1` for verbose logs.
- `CB_DRY_RUN` (default: `0`)
  - Set `1` to print what would happen without actually creating a ticket.


## How It Works
1. The script resolves a Drush command (preferring DDEV, then local vendor bin, then system).
2. It reads the Drupal state variable `system.cron_last` (epoch seconds). If missing/invalid, it assumes `0` (never ran).
3. It compares the age to `CB_THRESHOLD_SECONDS`.
4. If stale and no ticket was already sent for the same stale window, it creates a new ticket via the CodebaseHQ API.
5. On success, it records the send time in `CB_STATE_FILE` to avoid duplicate tickets until cron runs again.


## CodebaseHQ API Endpoint
- The script posts XML to:
  https://api3.codebasehq.com/<PROJECT_PERMALINK>/tickets.xml
- If the `.xml` variant responds with HTTP 404, the script retries without the `.xml` extension, relying on the `Accept: application/xml` header.
- Authentication uses HTTP Basic with `CB_USERNAME:CB_API_KEY`.


## Usage Examples
One-off dry run:
CB_PROJECT_PERMALINK=myproj CB_USERNAME=acct/user CB_API_KEY=abc123 CB_DRY_RUN=1 ./cron_monitor.sh

Persistent environment setup:
export CB_PROJECT_PERMALINK=myproj
export CB_USERNAME=acct/user
export CB_API_KEY=abc123
export CB_THRESHOLD_SECONDS=21600  # 6 hours
export CB_TICKET_PRIORITY=4
./cron_monitor.sh

With DDEV (auto-detected):
./cron_monitor.sh

Multisite example (site URI):
CB_PROJECT_PERMALINK=myproj CB_USERNAME=acct/user CB_API_KEY=abc123 CB_MULTISITE_HOST=example.com ./cron_monitor.sh

Quiet crontab entry (every hour):
0 * * * * cd /path/to/project && CB_VERBOSE=0 ./cron_monitor.sh >/dev/null 2>&1


## Troubleshooting
- “Could not find drush”
  - Ensure DDEV is installed (for `ddev drush`) or that `./vendor/bin/drush` exists (Composer install) or `drush` is on PATH.
- API errors (e.g., HTTP 401/403/404)
  - Verify `CB_PROJECT_PERMALINK`, `CB_USERNAME`, and `CB_API_KEY`.
  - Confirm your account expects the endpoint format shown above. The script tries both `.xml` and without.
- No ticket created repeatedly
  - Check `.monitor_state/cron_monitor.last_sent`. The script records when it last created a ticket and won’t create another until cron runs again.


## Security Notes
- Consider injecting secrets (`CB_API_KEY`) via environment variables or a secure secret manager rather than committing them.
- If using crontab, avoid writing secrets directly in the cron line; source them from a protected file.


## Development
- Update environment variables by exporting them in your shell or placing them in your environment management tool.
- Run with `CB_VERBOSE=1` for detailed logs, or `CB_DRY_RUN=1` to verify payload without creating a ticket.
- The script uses `set -euo pipefail` and attempts to handle missing or malformed state values robustly.
