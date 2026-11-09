#!/usr/bin/env bash
# Pins the client build: syncs a Gethe/wow-ui-source checkout into
# .client-source/<flavor>, rewrites clientdata/<flavor>.json and regenerates
# the API snapshot and the atlas table for that build.
#
# Usage:
#   bash scripts/update-client-source.sh --sync     check out the pinned commit only
#   bash scripts/update-client-source.sh [commit]   pin a commit (default: the branch's newest) and regenerate
#
# FLAVOR picks the pin file (default: forever). SOURCE_DIR overrides the
# checkout. ART_REF repins Gethe/wow-ui-textures. An existing folder that is
# not a git checkout is never replaced.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flavor="${FLAVOR:-forever}"
pin_file="$repo_dir/clientdata/$flavor.json"
source_dir="${SOURCE_DIR:-$repo_dir/.client-source/$flavor}"

die() { echo "error: $*" >&2; exit 1; }
pin_field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); [v:=v[k] for k in sys.argv[2:]]; print(v)' "$pin_file" "$@"; }

[[ -f "$pin_file" ]] || die "no pin file $pin_file"
repository="$(pin_field wowUiSource repository)"
branch="$(pin_field wowUiSource branch)"
url="https://github.com/$repository.git"

sync() {
	local commit="$1"
	if [[ -e "$source_dir" && ! -d "$source_dir/.git" ]]; then
		die "$source_dir is not a git checkout; move it aside once and rerun"
	fi
	if [[ ! -d "$source_dir/.git" ]]; then
		git init -q "$source_dir"
		git -C "$source_dir" remote add origin "$url"
	fi
	if [[ "$(git -C "$source_dir" rev-parse -q --verify HEAD 2>/dev/null)" != "$commit" ]]; then
		git -C "$source_dir" fetch -q --depth 1 origin "$commit"
		git -C "$source_dir" checkout -q --detach FETCH_HEAD
	fi
	echo "$source_dir at $commit ($(tr -d '[:space:]' < "$source_dir/version.txt"))"
}

if [[ "${1:-}" == "--sync" ]]; then
	sync "$(pin_field wowUiSource commit)"
	exit 0
fi

commit="${1:-$(git ls-remote "$url" "refs/heads/$branch" | cut -f1)}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "expected a full commit SHA, got '$commit'"
sync "$commit"
version="$(tr -d '[:space:]' < "$source_dir/version.txt")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected version.txt '$version'"
old_version="$(pin_field build)"

python3 - "$pin_file" "$commit" "$version" "${ART_REF:-}" <<'EOF'
import json, sys
path, commit, version, art = sys.argv[1:]
pin = json.load(open(path))
major, minor, patch, _ = map(int, version.split("."))
pin["build"], pin["interface"] = version, major * 10000 + minor * 100 + patch
pin["wowUiSource"]["commit"] = commit
if art:
    pin["art"]["ref"] = art
open(path, "w").write(json.dumps(pin, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
EOF

cd "$repo_dir"
sed -i -E "s|^API\.DEFAULT_BUILD = \".*\"$|API.DEFAULT_BUILD = \"$flavor-$version\"|" wowmock/api.lua
luajit scripts/api-snapshot.lua "$source_dir" "wowmock/snapshots/$flavor-$version.lua"
python3 -B scripts/atlas_catalog.py --flavor "$flavor" --update
if [[ "$old_version" != "$version" ]]; then
	echo "Build changed $old_version -> $version: review and remove the old snapshot and atlas table once nothing uses them"
fi
echo "Pinned $repository $commit ($flavor $version)"
