#!/usr/bin/env bash
#
# Commit-Dirty.sh — commit uncommitted working-tree changes in module clones.
#
# Run this BEFORE Cleanup-Forks.sh: that script's ~/Tmp backup bundles only *committed* refs, so any
# uncommitted working-tree change is the one thing it does NOT preserve. Commit (and optionally push)
# your dirty modules first so nothing is lost.
#
# For every module clone under modules/<group>/<name> with a dirty tree, this shows the change, asks
# for a commit message (per module), stages everything not gitignored, and commits. Optionally pushes.
# Idempotent (clean clones are skipped) and portable (auto-detects the monorepo).
#
# Usage:
#   bash Commit-Dirty.sh [MONOREPO_DIR]
#   Flags:
#     --message "text"   use this message for every dirty module (skips the per-module prompt)
#     --push             push to origin after each commit
#     --yes              accept the commit gate non-interactively (still needs a message via --message)
#     --dry-run          show what's dirty + would be committed; make no changes
#
set -uo pipefail

MSG=""; PUSH=0; ASSUME_YES=0; DRY_RUN=0; MONOREPO=""
while [ $# -gt 0 ]; do
	case "$1" in
		--message) MSG="${2:-}"; shift 2 ;;
		--push)    PUSH=1; shift ;;
		--yes)     ASSUME_YES=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		-*)        echo "Unknown flag: $1" >&2; exit 2 ;;
		*)         MONOREPO="$1"; shift ;;
	esac
done

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
info() { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_RESET}"; }
hdr()  { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

# locate the monorepo (walk up from the script dir / PWD for the manifest)
if [ -z "$MONOREPO" ]; then
	for tmpBase in "$(cd "$(dirname "$0")" && pwd)" "$PWD"; do
		tmpD="$tmpBase"
		while [ "$tmpD" != "/" ]; do
			[ -f "$tmpD/Retold-Modules-Manifest.json" ] && { MONOREPO="$tmpD"; break; }
			tmpD="$(dirname "$tmpD")"
		done
		[ -n "$MONOREPO" ] && break
	done
fi
if [ -z "$MONOREPO" ] || [ ! -d "$MONOREPO/modules" ]; then
	echo "Could not find the monorepo. Run from inside it, or pass its path." >&2; exit 1
fi
MONOREPO="$(cd "$MONOREPO" && pwd)"

hdr "commit dirty module clones"
info "monorepo: $MONOREPO"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN — no commits will be made."

tmpAny=0
while IFS= read -r tmpGitDir; do
	tmpDir="$(dirname "$tmpGitDir")"
	tmpName="$(basename "$tmpDir")"
	# dirty?  (porcelain covers modified, staged, and untracked-not-ignored)
	[ -z "$(git -C "$tmpDir" status --porcelain 2>/dev/null)" ] && continue
	tmpAny=1

	hdr "$tmpName"
	git -C "$tmpDir" -c color.status=always status --short
	info "  diff (tracked): $(git -C "$tmpDir" diff --shortstat | sed 's/^ *//')"

	if [ "$DRY_RUN" = 1 ]; then info "  (dry-run) would: git add -A && git commit"; continue; fi

	# message: --message wins; else prompt (unless --yes, which requires --message)
	tmpMessage="$MSG"
	if [ -z "$tmpMessage" ]; then
		if [ "$ASSUME_YES" = 1 ]; then warn "  --yes needs --message; skipping $tmpName."; continue; fi
		printf '%s' "  commit message (empty = skip this module): "
		read -r tmpMessage
		[ -z "$tmpMessage" ] && { warn "  skipped."; continue; }
	elif [ "$ASSUME_YES" != 1 ]; then
		printf '%s' "  commit ${tmpName} with message \"$tmpMessage\"? [yes]: "
		read -r tmpReply; [ "$tmpReply" = "yes" ] || { warn "  skipped."; continue; }
	fi

	git -C "$tmpDir" add -A
	if git -C "$tmpDir" commit -m "$tmpMessage" >/dev/null 2>&1; then
		ok "  committed $(git -C "$tmpDir" rev-parse --short HEAD): $tmpMessage"
		if [ "$PUSH" = 1 ]; then
			tmpBranch="$(git -C "$tmpDir" rev-parse --abbrev-ref HEAD)"
			if git -C "$tmpDir" push origin "$tmpBranch" >/dev/null 2>&1; then ok "  pushed to origin/$tmpBranch"
			else warn "  push failed (check the remote / auth)"; fi
		fi
	else
		warn "  nothing committed (only ignored files changed?)"
	fi
done < <(find "$MONOREPO/modules" -mindepth 3 -maxdepth 3 -name .git 2>/dev/null | sort)

[ "$tmpAny" = 0 ] && ok "No dirty module clones — nothing to commit."
hdr "Done."
