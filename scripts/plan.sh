#!/usr/bin/env bash
# plan.sh <checkout directory>: checks a run's inputs, clones the version, and says what to build.
#
# Inputs (environment, from workflow_dispatch): RUN, EXTENSION, VERSION, REPOSITORY, COMMIT,
# LICENSE_KEYS. Outputs (to $GITHUB_OUTPUT, or stdout): builds (a JSON array of {duckdb, ref,
# duckdb_commit, commit}: a DuckDB version's name, the ref naming it to the build tools (a release's
# tag, a development build's full commit), the commit DuckDB is checked out at, and the extension's
# commit built for it), exclude and opt_in (the fork's exclude_archs and opt_in_archs).
#
# The platforms: every platform of the fork's matrix, its opt-in ones included, less the version's
# description.yml's extension.excluded_platforms and WebAssembly (kista serves none). The DuckDB
# versions: extension.duckdb_versions, either names (;-separated: each built from the version's
# commit) or a map of a name to the repository's commit built for it ("" for the version's), as
# DuckDB's community extensions name a ref per DuckDB line; without it, the DuckDB version whose
# commit the duckdb submodule names. A name is a release's tag, or a development build's source id
# (its commit's first 10 hex digits, as DuckDB names it). Only those in duckdb-versions are built.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:?usage: plan.sh <checkout directory>}
out=${GITHUB_OUTPUT:-/dev/stdout}
fail() { echo "plan: $*" >&2; exit 1; }

# the inputs: names a build takes, never interpolated into a command
[[ ${RUN:-} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "run: Enterest's run id"
[[ ${EXTENSION:-} =~ ^[a-z0-9_]{1,64}$ ]] || fail "extension: [a-z0-9_]{1,64}"
[[ ${VERSION:-} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ && $VERSION != *..* ]] || fail "version: a release tag's name"
[[ ${REPOSITORY:-} =~ ^https://[A-Za-z0-9.-]+(:443)?/[A-Za-z0-9._~/-]+$ && $REPOSITORY != *..* ]] || fail "repository: an https git URL"
[[ ${COMMIT:-} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "commit: a full commit hash"
# PEM public keys only (zero to four): each line a marker or base64, the markers paired in order
awk '
	/^-----BEGIN PUBLIC KEY-----$/ { if (open) exit 1; open = 1; n++; next }
	/^-----END PUBLIC KEY-----$/ { if (!open) exit 1; open = 0; next }
	/^[A-Za-z0-9+\/=]{1,64}$/ { if (!open) exit 1; next }
	/^$/ { next }
	{ exit 1 }
	END { if (open || n > 4) exit 1 }' <<<"${LICENSE_KEYS:-}" || fail "license_keys: PEM public keys only, at most four"
command -v yq >/dev/null && yq --version | grep -q 'mikefarah' || fail "yq (mikefarah's, v4) is needed: scripts/yq.sh"

# the version: its tree at the commit (no checkout), and its submodules' commits
git init -q "$dir"
git -C "$dir" remote add origin "$REPOSITORY"
git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$COMMIT" 2>/dev/null ||
	git -C "$dir" fetch -q --filter=blob:none --tags origin '+refs/heads/*:refs/remotes/origin/*'
git -C "$dir" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "the commit $COMMIT is not in $REPOSITORY"

description=$(git -C "$dir" show "$COMMIT:description.yml" 2>/dev/null || true)
yaml() { [ -z "$description" ] || printf '%s' "$description" | yq -o=json "$1"; }
# a string (;-separated, as the community's descriptors mostly write it) or a list
excluded=$(yaml '.extension.excluded_platforms // ""' | jq -r '
	if type == "string" then . elif type == "array" then map(tostring) | join(";")
	else error("excluded_platforms: a string or a list") end' | tr ',' ';' | tr -d '[:space:]')
# platform names only: the list reaches the build tools' matrix step
[[ $excluded =~ ^([a-z0-9_]+(;[a-z0-9_]+)*)?$ ]] || fail "excluded_platforms: platform names ([a-z0-9_]), ;-separated"
# {name: commit} ("" for the version's commit), from a string of names or a map
requested=$(yaml '.extension.duckdb_versions // ""' | jq -c '
	if type == "string" then [splits("[;,]") | gsub("\\s"; "") | select(. != "") | {(.): ""}] | add // {}
	elif type == "object" then with_entries(.value |= (. // "" | tostring))
	else error("not names") end') ||
	fail "duckdb_versions: names (a source id quoted, as YAML reads digits as a number), or a map of a name to a commit"
[ -n "$requested" ] || requested='{}'

# the platforms
wasm="wasm_mvp;wasm_eh;wasm_threads"
opt_in=""
for p in linux_amd64_musl linux_arm64_musl osx_amd64 windows_arm64; do
	case ";$excluded;" in *";$p;"*) ;; *) opt_in="${opt_in:+$opt_in;}$p" ;; esac
done
exclude="${excluded:+$excluded;}$wasm"

# the DuckDB versions (name, commit, and dev for a development build), each with the commit built
# for it; a development build's name is its commit's source id. (DUCKDB_VERSIONS_FILE is the tests';
# the workflow never sets it.) A name or a commit listed twice is refused.
known=$(grep -v '^#' "${DUCKDB_VERSIONS_FILE:-$here/duckdb-versions}" | awk '
	NF == 0 { next }
	seen[$1]++ || seen[$2]++ { exit 1 }
	!(NF == 2 || NF == 3 && $3 == "dev") { exit 1 }
	$2 !~ /^[0-9a-f]+$/ || length($2) != 40 && length($2) != 64 { exit 1 }
	NF == 3 && $1 != substr($2, 1, 10) { exit 1 }
	NF == 2 && $1 !~ /^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$/ { exit 1 }
	{ print }') || fail "duckdb-versions: a line is <tag> <commit>, or <source id> <commit> dev"
names=$(awk '{print $1}' <<<"$known" | paste -sd, -)
if [ "$requested" = '{}' ]; then
	sub=$(git -C "$dir" ls-tree "$COMMIT" duckdb | awk '$2 == "commit" {print $3}')
	[ -n "$sub" ] || fail "no extension.duckdb_versions in description.yml and no duckdb submodule"
	tag=$(awk -v c="$sub" '$2 == c {print $1}' <<<"$known")
	[ -n "$tag" ] || fail "the duckdb submodule's commit $sub is no DuckDB version Enterest builds for: $names"
	requested=$(jq -nc --arg t "$tag" '{($t): ""}')
fi
builds='[]'
while IFS=$'\t' read -r v c; do
	if ! awk -v t="$v" '$1 == t {f = 1} END {exit !f}' <<<"$known"; then
		echo "plan: DuckDB $v is not one Enterest builds for ($names): skipped" >&2
		continue
	fi
	# the ref DuckDB is built at (a release's tag, a development build's commit), and its commit
	ref=$(awk -v t="$v" '$1 == t {print (NF == 3 ? $2 : $1)}' <<<"$known")
	duckdb_commit=$(awk -v t="$v" '$1 == t {print $2}' <<<"$known")
	c=${c:-$COMMIT}
	[[ $c =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "duckdb_versions $v: a full commit hash, or \"\""
	if ! git -C "$dir" cat-file -e "$c^{commit}" 2>/dev/null; then
		git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$c" 2>/dev/null || true
		git -C "$dir" cat-file -e "$c^{commit}" 2>/dev/null || fail "duckdb_versions $v: the commit $c is not in $REPOSITORY"
	fi
	builds=$(jq -c --arg d "$v" --arg r "$ref" --arg dc "$duckdb_commit" --arg c "$c" \
		'. + [{duckdb: $d, ref: $r, duckdb_commit: $dc, commit: $c}]' <<<"$builds")
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$requested")
[ "$builds" != '[]' ] || fail "none of the DuckDB versions $(jq -r 'keys | join(",")' <<<"$requested") is one Enterest builds for: $names"

{
	echo "builds=$builds"
	echo "exclude=$exclude"
	echo "opt_in=$opt_in"
} >>"$out"
