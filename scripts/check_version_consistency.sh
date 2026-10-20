#!/usr/bin/env bash
#
# Kept so the name in ADR-0001 still resolves. The version locations now live
# in scripts/check-release.sh (the single authoritative list); this runs only
# that section.

set -euo pipefail

exec "$(dirname "$0")/check-release.sh" versions
