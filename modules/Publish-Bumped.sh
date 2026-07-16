#!/usr/bin/env bash
#
# Publish-Bumped.sh -- npm-publish every retold module whose local package.json version is not yet on npm.
#
# A module is a candidate when npm already knows the package (it has a publish history) AND the local
# version has never been published. That is exactly "version bumped, not published". It is NOT a candidate
# when npm has never heard of it (private / work-in-progress) or when the local version is already on npm.
#
# DRY RUN by default: it lists what it would publish and touches nothing. Pass --yes to actually publish.
#
#   ./Publish-Bumped.sh          # show the plan, publish nothing
#   ./Publish-Bumped.sh --yes    # publish the listed packages
#
# Safety gates (a skip, never a silent drop):
#   - EXCLUDE list: never publish these even if bumped (meadow-endpoints: npm 'latest' is 2.x for
#     backwards-compat consumers; the 4.x line is intentionally local-only).
#   - dirty working tree: npm publish ships the tree, uncommitted files included, so a dirty module is
#     skipped. Commit first.
#   - unpushed commits: a publish should follow its push (so the registry's gitHead is reachable), so a
#     module ahead of its upstream is skipped. Push first.
#
set -o pipefail

ROOT="$HOME/Code/retold"
MODROOT="$ROOT/modules"

DO_PUBLISH=0
[ "${1:-}" = "--yes" ] && DO_PUBLISH=1

# Never auto-publish these, even when the local version is ahead of npm.
EXCLUDE=( "meadow-endpoints" )
is_excluded() { local n="$1"; for e in "${EXCLUDE[@]}"; do [ "$e" = "$n" ] && return 0; done; return 1; }

# Publishing needs an npm login; a dry run does not, so only hard-require it for --yes.
who=$(npm whoami 2>/dev/null) || who=""
if [ "$DO_PUBLISH" -eq 1 ] && [ -z "$who" ]; then echo "Not logged in to npm (run: npm login) -- aborting."; exit 1; fi
echo "npm user: ${who:-<not logged in>}"
if [ "$DO_PUBLISH" -eq 1 ]; then echo "MODE: PUBLISH"; else echo "MODE: dry-run (pass --yes to publish)"; fi
echo

# The umbrella root plus every group/module repo.
REPOS=("$ROOT")
for d in "$MODROOT"/*/*/ ; do [ -e "${d%/}/.git" ] && REPOS+=("${d%/}"); done

candidates=()        # "dir|name|localver|latest"
skipped_dirty=()
skipped_unpushed=()
skipped_neverpub=()

for d in "${REPOS[@]}"; do
	name=$(node -e "try{process.stdout.write(require('$d/package.json').name||'')}catch(e){}" 2>/dev/null)
	ver=$(node -e "try{process.stdout.write(require('$d/package.json').version||'')}catch(e){}" 2>/dev/null)
	[ -n "$name" ] && [ -n "$ver" ] || continue
	is_excluded "$name" && { echo "excluded: $name"; continue; }

	# Gate on a real published 'latest': a name npm does not resolve (or that has no release yet) has none,
	# so it is never-published (private / WIP), not a bump. This is the reliable signal.
	latest=$(npm view "$name" version 2>/dev/null)
	if [ -z "$latest" ]; then skipped_neverpub+=("$name ($ver)"); continue; fi

	# is this exact version already on npm?
	alljson=$(npm view "$name" versions --json 2>/dev/null)
	if printf '%s' "$alljson" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{let j=JSON.parse(s);j=Array.isArray(j)?j:[j];process.exit(j.includes(process.argv[1])?0:1)}catch(e){process.exit(1)}})" "$ver"; then
		continue   # already published this version -> in sync
	fi

	dirty=$(git -C "$d" status --porcelain 2>/dev/null | grep -c .)
	if [ "${dirty:-0}" -gt 0 ]; then skipped_dirty+=("$name ($ver): $dirty uncommitted"); continue; fi

	up=$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
	if [ -n "$up" ]; then
		ahead=$(git -C "$d" rev-list --count "$up"..HEAD 2>/dev/null)
		if [ "${ahead:-0}" -gt 0 ]; then skipped_unpushed+=("$name ($ver): $ahead unpushed"); continue; fi
	fi

	candidates+=("$d|$name|$ver|$latest")
done

echo "== WILL PUBLISH (version not on npm, tree clean, pushed) =="
[ ${#candidates[@]} -eq 0 ] && echo "  (none)"
for c in "${candidates[@]}"; do IFS='|' read -r d name ver latest <<<"$c"; printf "  %-34s %-10s (npm latest: %s)\n" "$name" "$ver" "${latest:-none}"; done

if [ ${#skipped_dirty[@]} -gt 0 ]; then echo; echo "== skipped: dirty tree (commit first) =="; printf '  %s\n' "${skipped_dirty[@]}"; fi
if [ ${#skipped_unpushed[@]} -gt 0 ]; then echo; echo "== skipped: unpushed (git push first) =="; printf '  %s\n' "${skipped_unpushed[@]}"; fi
if [ ${#skipped_neverpub[@]} -gt 0 ]; then echo; echo "== skipped: never published (private/WIP, left alone) =="; printf '  %s\n' "${skipped_neverpub[@]}"; fi

if [ "$DO_PUBLISH" -ne 1 ]; then
	echo; echo "Dry run -- nothing published. Re-run with --yes to publish the ${#candidates[@]} package(s) above."
	exit 0
fi

echo; echo "Publishing ${#candidates[@]} package(s)..."
ok=0; fail=0
for c in "${candidates[@]}"; do
	IFS='|' read -r d name ver latest <<<"$c"
	echo "---- npm publish $name@$ver ----"
	if ( cd "$d" && npm publish ); then echo "  OK   $name@$ver"; ok=$((ok+1)); else echo "  FAIL $name@$ver"; fail=$((fail+1)); fi
done
echo; echo "Done: $ok published, $fail failed."
