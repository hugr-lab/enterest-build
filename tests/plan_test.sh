#!/usr/bin/env bash
# The plan's tests: a version's repository made here (served as an https URL through git's
# insteadOf), its description.yml in each form, and inputs refused.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
v200=$(awk '$1 == "v2.0.0" {print $2}' "$here/duckdb-versions")

# the developer's repository: a duckdb submodule at v2.0.0's commit, and a second commit
repo=$work/ext
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
other=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" update-index --add --cacheinfo "160000,$v200,duckdb"
describe() {
	if [ -n "$1" ]; then printf '%s\n' "$1" >"$repo/description.yml"; git -C "$repo" add description.yml; fi
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m version
	git -C "$repo" rev-parse HEAD
}
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$repo.insteadOf" GIT_CONFIG_VALUE_0=https://git.example/dev/ext

plan() { # plan <commit> [license keys]: the plan's output, or its error
	local clone out
	clone=$(mktemp -d "$work/clone.XXXXXX")
	out=$clone.out
	: >"$out"
	if RUN=0b7c6c5e-2f7e-4d55-9b3e-5d5b8c1c9a01 EXTENSION=my_ext VERSION=v1.0.0 REPOSITORY=https://git.example/dev/ext COMMIT=$1 \
		LICENSE_KEYS=${2:-} GITHUB_OUTPUT=$out "$here/scripts/plan.sh" "$clone" 2>"$out.err"; then
		cat "$out"
	else
		echo "error: $(tail -1 "$out.err")"
	fi
}
want() { # want <what> <output> <expected line>
	grep -qxF -- "$3" <<<"$2" || { printf 'FAIL %s: want %s\n%s\n' "$1" "$3" "$2" >&2; exit 1; }
	echo "ok   $1"
}

c=$(describe "")
out=$(plan "$c")
want "no description: the submodule's release" "$out" "builds=[{\"duckdb\":\"v2.0.0\",\"commit\":\"$c\"}]"
want "no description: every platform but WebAssembly" "$out" "exclude=wasm_mvp;wasm_eh;wasm_threads"
want "no description: the opt-in platforms" "$out" "opt_in=linux_amd64_musl;linux_arm64_musl;osx_amd64;windows_arm64"

c=$(describe $'extension:\n  name: my_ext\n  excluded_platforms: "windows_arm64;linux_amd64_musl"\n  duckdb_versions: "v2.0.0; v1.4.0"')
out=$(plan "$c")
want "tags: those Enterest builds for" "$out" "builds=[{\"duckdb\":\"v2.0.0\",\"commit\":\"$c\"}]"
want "excluded platforms" "$out" "exclude=windows_arm64;linux_amd64_musl;wasm_mvp;wasm_eh;wasm_threads"
want "excluded opt-in platforms" "$out" "opt_in=linux_arm64_musl;osx_amd64"

c=$(describe "$(printf 'extension:\n  duckdb_versions:\n    v2.0.0: %s\n' "$other")")
out=$(plan "$c")
want "a commit per DuckDB version" "$out" "builds=[{\"duckdb\":\"v2.0.0\",\"commit\":\"$other\"}]"

c=$(describe $'extension:\n  duckdb_versions:\n    v2.0.0: abc')
want "a short commit" "$(plan "$c")" "error: plan: duckdb_versions v2.0.0: a full commit hash, or \"\""
c=$(describe "$(printf 'extension:\n  duckdb_versions:\n    v2.0.0: %s\n' "$(printf 'f%.0s' {1..40})")")
want "a commit not in the repository" "$(plan "$c")" "error: plan: duckdb_versions v2.0.0: the commit $(printf 'f%.0s' {1..40}) is not in https://git.example/dev/ext"
c=$(describe $'extension:\n  excluded_platforms: "x\\"$(id)\\""')
want "excluded platforms: names only" "$(plan "$c")" "error: plan: excluded_platforms: platform names ([a-z0-9_]), ;-separated"
c=$(describe $'extension:\n  excluded_platforms: "osx_amd64,windows_arm64"\n  duckdb_versions: "v2.0.0,v2.0.0"')
out=$(plan "$c")
want "a comma, and a version twice" "$out" "builds=[{\"duckdb\":\"v2.0.0\",\"commit\":\"$c\"}]"
want "a comma between platforms" "$out" "exclude=osx_amd64;windows_arm64;wasm_mvp;wasm_eh;wasm_threads"
c=$(describe $'extension:\n  excluded_platforms:\n    - "wasm_mvp"\n    - "osx_amd64"')
want "excluded platforms as a list (tresor's)" "$(plan "$c")" "exclude=wasm_mvp;osx_amd64;wasm_mvp;wasm_eh;wasm_threads"
c=$(describe $'extension:\n  duckdb_versions: "v1.4.0"')
want "no version Enterest builds for" "$(plan "$c")" "error: plan: none of the DuckDB versions v1.4.0 is one Enterest builds for: v2.0.0"
want "keys: PEM only" "$(plan "$c" $'-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n$(id)')" "error: plan: license_keys: PEM public keys only, at most four"
want "keys: a key left open" "$(plan "$c" $'-----BEGIN PUBLIC KEY-----\nAAAA\n$(id)')" "error: plan: license_keys: PEM public keys only, at most four"
key=$'-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n'
want "keys: five" "$(plan "$c" "$key$key$key$key$key")" "error: plan: license_keys: PEM public keys only, at most four"
want "a commit not in the repository" "$(plan "$(printf 'e%.0s' {1..40})")" "error: plan: the commit $(printf 'e%.0s' {1..40}) is not in https://git.example/dev/ext"

# inputs that are not what a build takes
for bad in "EXTENSION=My-Ext" "VERSION=v1;id" "VERSION=a..b" "REPOSITORY=http://git.example/x" "REPOSITORY=https://git.example/x y" "COMMIT=abc" "RUN=x"; do
	if env RUN=0b7c6c5e-2f7e-4d55-9b3e-5d5b8c1c9a01 EXTENSION=my_ext VERSION=v1.0.0 REPOSITORY=https://git.example/dev/ext COMMIT="$c" "$bad" \
		GITHUB_OUTPUT=/dev/null "$here/scripts/plan.sh" "$(mktemp -d "$work/bad.XXXXXX")" 2>/dev/null; then
		echo "FAIL $bad accepted" >&2
		exit 1
	fi
	echo "ok   refused: $bad"
done
echo "plan: ok"
