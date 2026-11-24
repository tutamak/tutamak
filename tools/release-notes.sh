#!/bin/bash
# Prints the release notes of one version from CHANGELOG.md: the lines under its `## [<version>]`
# heading (Keep a Changelog), up to the next `## ` or the link definitions at the end of the file
# (`[0.1.0]: https://…`), with blank lines trimmed at both ends. Prints
# nothing, and succeeds, when there is no such section or it is empty; `make release` stops on an
# empty result, so no version is released without notes.
#
#   tools/release-notes.sh <version> [changelog]
#   tools/release-notes.sh --self-test
set -euo pipefail

notes() {
  awk -v heading="## [$1]" '
    index($0, heading) == 1 && (length($0) == length(heading) || substr($0, length(heading) + 1, 1) == " ") {
      inside = 1; next
    }
    inside && (/^## / || /^\[[^]]+\]: /) { exit }
    inside { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n;  while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }' "$2"
}

if [ "${1:-}" = "--self-test" ]; then
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  cat > "$dir/CHANGELOG.md" <<'TEXT'
# Changelog

## [Unreleased]

- Not yet.

## [0.2.0] - 2026-12-01

## [0.1.0] - 2026-11-25

### Added

- First.

## [0.1.00]

- Not 0.1.0.

## [0.0.1] - 2026-11-01

- The last one.

[Unreleased]: https://example.com/compare/v0.1.0...HEAD
[0.1.0]: https://example.com/releases/tag/v0.1.0
TEXT
  fail() { echo "release-notes: self-test failed: $1" >&2; exit 1; }
  [ "$(notes 0.1.0 "$dir/CHANGELOG.md")" = "$(printf '### Added\n\n- First.')" ] || fail "a version's section"
  [ -z "$(notes 0.2.0 "$dir/CHANGELOG.md")" ] || fail "an empty section must give nothing"
  [ -z "$(notes 0.3.0 "$dir/CHANGELOG.md")" ] || fail "a missing section must give nothing"
  [ "$(notes Unreleased "$dir/CHANGELOG.md")" = "- Not yet." ] || fail "the Unreleased section"
  [ "$(notes 0.0.1 "$dir/CHANGELOG.md")" = "- The last one." ] || fail "the last section, before the links"
  echo "release-notes: self-test passed"
  exit 0
fi

[ $# -ge 1 ] || { echo "usage: $0 <version> [changelog] | --self-test" >&2; exit 2; }
file="${2:-$(dirname "$0")/../CHANGELOG.md}"
[ -f "$file" ] || exit 0
notes "$1" "$file"
