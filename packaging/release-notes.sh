#!/usr/bin/env bash
#
# release-notes.sh -- print one version's section of the CHANGELOG.
#
# Usage:
#   packaging/release-notes.sh 0.1.0
#
# Environment overrides:
#   CHANGELOG   the file to read (default: CHANGELOG.md beside this repository)
#
# The release body on GitHub is the changelog entry, not a second description
# written by hand: two accounts of the same release drift, and the one nobody
# reads while writing is the one that goes stale.
#
# Exits 1 when the version has no section, so a release cannot ship with an
# empty body.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
CHANGELOG="${CHANGELOG:-$HERE/CHANGELOG.md}"

[ -n "$VERSION" ] || { echo "usage: release-notes.sh VERSION" >&2; exit 2; }

# Everything between this version's heading and the next one at the same level.
# The heading is "## 0.1.0", "## 0.1.0 - 2026-09-07", or Keep a Changelog's
# "## [0.1.0]: 2026-09-07"; brackets and the colon are stripped before comparing.
# The compare is a string one, so a dot in the version cannot stand in for any
# other character.
notes="$(awk -v version="$VERSION" '
  function bare(f) { gsub(/\[/, "", f); gsub(/\]/, "", f); gsub(/:/, "", f); return f }
  !found && $1 == "##" && bare($2) == version { found = 1; next }
  found && $1 == "##" { exit }
  found { print }
' "$CHANGELOG")"

# Trim the blank lines the heading boundaries leave behind.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$notes" ]; then
  echo "release-notes.sh: no section for $VERSION in $CHANGELOG" >&2
  exit 1
fi

# The changelog wraps its lines, and a release page renders every newline as a
# break, so each paragraph and list item is joined back onto one line. Headings,
# table rows, fenced code and link definitions ("[1.0.0]: https://...") are left
# exactly as written: two definitions joined onto one line define neither.
printf '%s\n' "$notes" | awk '
  function flush() { if (buf != "") print buf; buf = "" }
  /^[[:space:]]*```/ { flush(); fenced = !fenced; print; next }
  fenced { print; next }
  /^[[:space:]]*$/ { flush(); print; next }
  /^[[:space:]]*\|/ || /^#+ / { flush(); print; next }
  /^[[:space:]]*\[[^]]+\]:[[:space:]]/ { flush(); print; next }
  /^[[:space:]]*([-*+>] |[0-9]+\. )/ { flush(); buf = $0; next }
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    buf = (buf == "") ? $0 : buf " " line
  }
  END { flush() }
'
