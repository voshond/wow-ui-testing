#!/usr/bin/env bash
# Fetches the pinned wow-ui-testing library into .wut/ and the third-party
# addons listed in wut.config.lua into .wut/addons/<name>/: git pins (source +
# ref) as a tree, release zips (url + sha256) checked and unzipped. Addon repos
# keep a copy of this script; run it from (or pass) the addon repo's root.
#
#   bash scripts/fetch-wut.sh [repo root]
#
# .wut-version holds the library's full commit SHA (the first word of its
# first non-comment line). Prints the library folder on stdout, so
#   lib="$(bash scripts/fetch-wut.sh)" && luajit "$lib/wowtest/cli.lua" -j
#
# WUT_DIR      use this local library checkout instead of downloading one
# WUT_REPO     library repository (default: voshond/wow-ui-testing)
# WUT_SOURCE   fetch the library from this local git repository instead
# WUT_CONFIG   host config (default: wut.config.lua, then tests/wut.config.lua)
# GITHUB_TOKEN / GH_TOKEN (or a logged-in gh) are used when set: they lift
# GitHub's anonymous rate limit and reach private forks.
set -euo pipefail
cd "${1:-$PWD}"
wut_dir="$PWD/.wut"
library_source="${WUT_SOURCE:-${WUT_REPO:-voshond/wow-ui-testing}}"

die() { echo "fetch-wut: $*" >&2; exit 1; }
say() { echo "fetch-wut: $*" >&2; }

token() {
	local value="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
	if [[ -z "$value" ]] && command -v gh >/dev/null; then value="$(gh auth token 2>/dev/null || true)"; fi
	printf '%s' "$value"
}

# Extracts <source> at <ref> into the new folder <staging>, with .wut-ref.
fetch_tree() {
	local source="$1" ref="$2" staging="$3" scratch
	scratch="$(mktemp -d)"
	mkdir -p "$staging"
	if [[ "$source" == /* ]]; then
		git -C "$source" archive --format=tar "$ref" | tar -x -C "$staging"
	else
		local auth=() url="https://codeload.github.com/$source/tar.gz/$ref" secret
		secret="$(token)"
		if [[ -n "$secret" ]]; then
			url="https://api.github.com/repos/$source/tarball/$ref"
			auth=(-H "Authorization: Bearer $secret")
		fi
		curl --fail --silent --show-error --location --retry 3 --max-time 300 "${auth[@]}" "$url" -o "$scratch/source.tar.gz"
		tar -xzf "$scratch/source.tar.gz" -C "$staging" --strip-components=1
	fi
	rm -rf -- "$scratch"
	printf '%s\n' "$ref" > "$staging/.wut-ref"
}

current_ref() { cat "$1/.wut-ref" 2>/dev/null || true; }

# Several fetches may run at once (parallel test runners): .wut.lock holds the
# owner's pid, and each run stages its downloads in its own .wut.new.XXXXXX.
lock_dir="$wut_dir.lock"
lock_wait="${WUT_LOCK_WAIT:-600}"
locked=""
staging_root=""

release() {
	if [[ -n "$staging_root" ]]; then rm -rf -- "$staging_root"; fi
	if [[ -n "$locked" ]]; then rm -rf -- "$lock_dir"; fi
}
trap release EXIT

lock() {
	local waited=0 owner
	until mkdir "$lock_dir" 2>/dev/null; do
		owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
		if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
			say "removing the stale lock of process $owner"
			rm -rf -- "$lock_dir"
			continue
		fi
		if (( waited == 0 )); then say "waiting for another fetch to finish"; fi
		if (( waited >= lock_wait * 5 )); then die "$lock_dir is still held after ${lock_wait}s; remove it if no fetch is running"; fi
		sleep 0.2
		waited=$((waited + 1))
	done
	locked=1
	printf '%s\n' "$$" > "$lock_dir/pid"
	staging_root="$(mktemp -d "$wut_dir.new.XXXXXX")"
}

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{ print $1 }'; else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

# Downloads the release zip <url>, checks it against <digest> and unpacks it
# into the new folder <staging>, with .wut-ref.
fetch_release() {
	local name="$1" url="$2" digest="$3" staging="$4" scratch actual
	scratch="$(mktemp -d)"
	curl --fail --silent --show-error --location --retry 3 --max-time 300 -A "fetch-wut" "$url" -o "$scratch/release.zip"
	actual="$(sha256 "$scratch/release.zip")"
	if [[ "$actual" != "$digest" ]]; then
		rm -rf -- "$scratch"
		die "release $name: sha256 $actual does not match the pinned $digest"
	fi
	mkdir -p "$staging"
	unzip -q "$scratch/release.zip" -d "$staging"
	rm -rf -- "$scratch"
	printf '%s\n' "$digest" > "$staging/.wut-ref"
}

lock

if [[ -n "${WUT_DIR:-}" ]]; then
	lib="$(cd "$WUT_DIR" && pwd)"
	say "using the local library in $lib (WUT_DIR)"
else
	[[ -f .wut-version ]] || die "no .wut-version in $PWD"
	sha="$(grep -v '^[[:space:]]*\(#\|$\)' .wut-version | head -n 1 | awk '{ print $1 }')"
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die ".wut-version must start with a full commit SHA, got '$sha'"
	if [[ "$(current_ref "$wut_dir")" == "$sha" ]]; then
		say "library $sha already in .wut"
	else
		staging="$staging_root/library"
		fetch_tree "$library_source" "$sha" "$staging"
		if [[ -d "$wut_dir/addons" ]]; then mv "$wut_dir/addons" "$staging/addons"; fi
		rm -rf -- "$wut_dir"
		mv "$staging" "$wut_dir"
		say "fetched library $sha into .wut"
	fi
	lib="$wut_dir"
fi

has_config() {
	if [[ -n "${WUT_CONFIG:-}" ]]; then return 0; fi
	[[ -f wut.config.lua || -f tests/wut.config.lua ]]
}

addons=""
if ! has_config; then
	say "no wut.config.lua; skipping addons"
elif [[ -f "$lib/wowtest/addons.lua" ]]; then
	lua="$(command -v luajit || command -v lua5.1 || true)"
	[[ -n "$lua" ]] || die "LuaJIT or Lua 5.1 is required to read wut.config.lua"
	addons="$("$lua" "$lib/wowtest/addons.lua" ${WUT_CONFIG:+"$WUT_CONFIG"})" || die "cannot read the addons from wut.config.lua"
else
	say "this library version has no third-party addon support; skipping addons"
fi

declare -A wanted=()
while IFS=$'\t' read -r name source ref toc; do
	[[ -n "$name" ]] || continue
	wanted[$name]=1
	destination="$wut_dir/addons/$name"
	if [[ "$(current_ref "$destination")" == "$ref" ]]; then
		say "addon $name $ref already in .wut/addons"
	else
		staging="$staging_root/addon-$name"
		if [[ "$source" == https://* || "$source" == file://* ]]; then
			fetch_release "$name" "$source" "$ref" "$staging"
		else
			fetch_tree "$source" "$ref" "$staging"
		fi
		mkdir -p "$wut_dir/addons"
		rm -rf -- "$destination"
		mv "$staging" "$destination"
		say "fetched addon $name $ref into .wut/addons"
	fi
	if [[ -n "$toc" ]]; then printf '%s\n' "$toc" > "$destination/.wut-toc"; else rm -f -- "$destination/.wut-toc"; fi
done <<< "$addons"

if [[ -d "$wut_dir/addons" ]]; then
	for folder in "$wut_dir/addons"/*/; do
		[[ -d "$folder" ]] || continue
		name="$(basename "$folder")"
		if [[ -z "${wanted[$name]:-}" ]]; then
			rm -rf -- "$folder"
			say "removed addon $name (no longer in wut.config.lua)"
		fi
	done
fi

say "package.path: $lib/?.lua;$lib/?/init.lua"
printf '%s\n' "$lib"
