#!/usr/bin/env bash
# Merges user-data.yml and network-config.yml (templates) with secrets.env
# to produce final files ready to copy onto the boot partition of an SD card.
#
# Usage:
#   ./build-user-data.sh
#
# Output:
#   ./user-data        (gitignored — copy this to the boot partition)
#   ./network-config    (gitignored — copy this to the boot partition)
#
# Also copy ./secrets.env to the boot partition — setup.sh reads it on first
# boot (see user-data.yml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$SCRIPT_DIR/secrets.env"

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

for name in user-data network-config; do
  envsubst < "$SCRIPT_DIR/$name.yml" > "$SCRIPT_DIR/$name"
  echo "✅  $name written to: $SCRIPT_DIR/$name"
done

echo ""
echo "Next: copy user-data, network-config, and secrets.env to the boot"
echo "partition of your SD card (replacing the existing user-data and"
echo "network-config files). secrets.env is read by setup.sh on first boot"
echo "and then deleted from the boot partition."
