#!/usr/bin/env bash
# Merges user-data.yml (template) with secrets.env to produce a final user-data
# file ready to copy onto the boot partition of an SD card.
#
# Usage:
#   ./build-user-data.sh
#
# Output:
#   ./user-data   (gitignored — copy this to the boot partition)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/user-data.yml"
SECRETS="$SCRIPT_DIR/secrets.env"
OUTPUT="$SCRIPT_DIR/user-data"

# ── Checks ────────────────────────────────────────────────────────────────────
if [[ ! -f "$SECRETS" ]]; then
  echo "❌  secrets.env not found."
  echo "    Run: cp secrets.env.example secrets.env && nano secrets.env"
  exit 1
fi

# Check for unfilled placeholders in secrets.env
if grep -qE '=$' "$SECRETS" 2>/dev/null; then
  echo "⚠️   The following secrets are still empty in secrets.env:"
  grep -E '=$' "$SECRETS" | grep -v '^#' | sed 's/=$//' | sed 's/^/    /'
  echo ""
  read -rp "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# Load secrets as environment variables, then use envsubst to replace tokens
set -a
# shellcheck disable=SC1090
source "$SECRETS"
set +a

envsubst < "$TEMPLATE" > "$OUTPUT"

echo "✅  user-data written to: $OUTPUT"
echo ""
echo "Next: copy $OUTPUT to the boot partition of your SD card,"
echo "replacing the existing user-data file."
