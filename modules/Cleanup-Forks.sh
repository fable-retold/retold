#!/usr/bin/env bash
#
# Cleanup-Forks.sh — retire the fork / upstream model across a retold synthetic monorepo.
#
# The old model: every "forkable" module was forked from the canonical org (fable-retold)
# to your personal GitHub account, cloned as origin=<you>/<module> with upstream=fable-retold.
# We're done with forks — modules now track local + remote (origin=fable-retold) + npm only.
#
# This one-time script, per module you have checked out:
#   1. REPORTS   what it would do + flags anything risky (fork ahead of canonical, dirty tree).
#   2. BACKS UP  every ref (git bundle --all) + the remote config to ~/Tmp before touching anything.
#   3. RE-POINTS origin -> fable-retold/<module> and drops the `upstream` remote.
#   4. DELETES   the personal GitHub fork (<you>/<module>) — gated, and only after the backup.
#   5. (opt)     flips Forkable:false in Retold-Modules-Manifest.json + regenerates the shell list.
#
# It is SAFE to re-run (idempotent): already-canonical modules and already-deleted forks are skipped.
# It discovers the fork owner from each clone's own origin URL, so it works for you and for colleagues
# on any machine, over whatever subset of modules that machine has checked out.
#
# Usage:
#   bash Cleanup-Forks.sh [MONOREPO_DIR]      # interactive; defaults to auto-detected monorepo
#
# Env / flags:
#   --yes            accept every gate non-interactively (for scripted runs — use with care)
#   --dry-run        report only; make no changes (this is also implied until you pass a gate)
#   --no-backup      skip the ~/Tmp backup step (NOT recommended)
#   --force          delete forks even if they look ahead of canonical (the backup still runs first)
#   --flip-manifest  also flip Forkable:false in the manifest + regenerate (one-time; commit once)
#   BACKUP_DIR=...   override the backup location (default: ~/Tmp/retold-fork-cleanup-<timestamp>)
#
set -uo pipefail

# ─────────────────────────────────────────── args ───────────────────────────────────────────
ASSUME_YES=0; DRY_RUN=0; DO_BACKUP=1; FORCE=0; FLIP_MANIFEST=0; MONOREPO=""
for tmpArg in "$@"; do
	case "$tmpArg" in
		--yes)           ASSUME_YES=1 ;;
		--dry-run)       DRY_RUN=1 ;;
		--no-backup)     DO_BACKUP=0 ;;
		--force)         FORCE=1 ;;
		--flip-manifest) FLIP_MANIFEST=1 ;;
		-h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
		-*)              echo "Unknown flag: $tmpArg" >&2; exit 2 ;;
		*)               MONOREPO="$tmpArg" ;;
	esac
done

CANONICAL_ORG_DEFAULT="fable-retold"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Tmp/retold-fork-cleanup-$(date +%Y%m%d-%H%M%S)}"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_RESET}"; }
err()  { printf '%s\n' "${C_RED}$*${C_RESET}" >&2; }
hdr()  { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

# A gate. Returns 0 (proceed) / 1 (skip). --yes auto-accepts; --dry-run auto-declines any mutation.
gate() {
	local tmpPrompt="$1"; local tmpExpect="${2:-yes}"
	if [ "$DRY_RUN" = "1" ]; then info "  (dry-run) would ask: $tmpPrompt"; return 1; fi
	if [ "$ASSUME_YES" = "1" ]; then return 0; fi
	local tmpReply=""
	printf '%s ' "${C_BOLD}${tmpPrompt}${C_RESET} [type '${tmpExpect}']:"
	read -r tmpReply
	[ "$tmpReply" = "$tmpExpect" ]
}

# ────────────────────────────────────── locate monorepo ─────────────────────────────────────
if [ -z "$MONOREPO" ]; then
	# walk up from the script dir, then from PWD, looking for the manifest.
	tmpStart="$(cd "$(dirname "$0")" && pwd)"
	for tmpBase in "$tmpStart" "$PWD"; do
		tmpD="$tmpBase"
		while [ "$tmpD" != "/" ]; do
			if [ -f "$tmpD/Retold-Modules-Manifest.json" ]; then MONOREPO="$tmpD"; break; fi
			tmpD="$(dirname "$tmpD")"
		done
		[ -n "$MONOREPO" ] && break
	done
fi
if [ -z "$MONOREPO" ] || [ ! -d "$MONOREPO/modules" ]; then
	err "Could not find the retold monorepo (looked for Retold-Modules-Manifest.json + a modules/ dir)."
	err "Run from inside the monorepo, or pass its path:  bash Cleanup-Forks.sh /path/to/retold"
	exit 1
fi
MONOREPO="$(cd "$MONOREPO" && pwd)"

# canonical org: from the generated module list if present, else the default.
CANONICAL_ORG="$CANONICAL_ORG_DEFAULT"
if [ -f "$MONOREPO/modules/Include-Retold-Module-List.sh" ]; then
	tmpOrg="$(grep -E '^canonicalOrg=' "$MONOREPO/modules/Include-Retold-Module-List.sh" | head -1 | sed -E 's/.*="?([^"]+)"?.*/\1/')"
	[ -n "$tmpOrg" ] && CANONICAL_ORG="$tmpOrg"
fi

HAVE_GH=0; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && HAVE_GH=1

hdr "retold fork cleanup"
info "monorepo:      $MONOREPO"
info "canonical org: $CANONICAL_ORG"
info "backup dir:    $BACKUP_DIR $([ "$DO_BACKUP" = 0 ] && echo '(disabled)')"
info "gh available:  $([ "$HAVE_GH" = 1 ] && echo yes || echo 'no — fork deletion will be skipped')"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN — no changes will be made."

# ─────────────────────────────────────── url helpers ────────────────────────────────────────
# owner from a github remote url (git@github.com:owner/repo.git | https://github.com/owner/repo(.git))
url_owner() { printf '%s' "$1" | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+)/.*#\2#'; }
url_repo()  { local tmpB; tmpB="$(basename "$1")"; printf '%s' "${tmpB%.git}"; }
# rebuild a canonical url for module $2 in the same scheme (ssh vs https) as the current origin $1
canonical_url() {
	local tmpOrigin="$1"; local tmpRepo="$2"
	if printf '%s' "$tmpOrigin" | grep -q '^git@'; then printf 'git@github.com:%s/%s.git' "$CANONICAL_ORG" "$tmpRepo"
	else printf 'https://github.com/%s/%s.git' "$CANONICAL_ORG" "$tmpRepo"; fi
}

# ─── which modules are forkable? (the ONLY ones we ever touch) ───
# Source of truth is the manifest: Forkable !== false means "canonical lives at fable-retold, you fork
# it." Forkable:false modules (owned by a person) are NOT forks — we must never re-point or delete them.
if ! command -v node >/dev/null 2>&1; then
	err "node is required (to read the manifest's Forkable flags). It ships with the retold toolchain."
	exit 1
fi
FORKABLE_NAMES=" $(node -e '
	const m=require(process.argv[1]); const out=[];
	for (const g of (m.Groups||[])) for (const mod of (g.Modules||[]))
		if (mod.Forkable !== false && mod.Forkable !== 0 && mod.Forkable !== "0") out.push(mod.Name);
	process.stdout.write(out.join(" "));
' "$MONOREPO/Retold-Modules-Manifest.json") "
is_forkable() { case "$FORKABLE_NAMES" in *" $1 "*) return 0;; *) return 1;; esac; }

# ─────────────────────────────────── discover fork clones ───────────────────────────────────
# A clone is a fork to clean iff: (a) the manifest marks it forkable, AND (b) its origin owner has
# drifted off the canonical org (i.e. it was forked to a personal account). Forkable modules already
# on fable-retold are skipped (idempotent); non-forkable modules are never considered.
declare -a FORK_DIRS FORK_NAMES FORK_OWNERS FORK_ORIGINS
tmpSkippedNonForkable=0
while IFS= read -r tmpGitDir; do
	tmpDir="$(dirname "$tmpGitDir")"
	tmpName="$(basename "$tmpDir")"
	tmpOrigin="$(git -C "$tmpDir" remote get-url origin 2>/dev/null)"
	[ -z "$tmpOrigin" ] && continue
	printf '%s' "$tmpOrigin" | grep -q 'github\.com' || continue
	tmpOwner="$(url_owner "$tmpOrigin")"
	[ "$tmpOwner" = "$CANONICAL_ORG" ] && continue     # already canonical — nothing to do (idempotent)
	if ! is_forkable "$tmpName"; then tmpSkippedNonForkable=$((tmpSkippedNonForkable+1)); continue; fi
	FORK_DIRS+=("$tmpDir"); FORK_NAMES+=("$tmpName"); FORK_OWNERS+=("$tmpOwner"); FORK_ORIGINS+=("$tmpOrigin")
done < <(find "$MONOREPO/modules" -mindepth 3 -maxdepth 3 -name .git 2>/dev/null | sort)
[ "$tmpSkippedNonForkable" -gt 0 ] && info "($tmpSkippedNonForkable non-forkable / personal module(s) off the canonical org left untouched.)"

tmpCount=${#FORK_DIRS[@]}
if [ "$tmpCount" -eq 0 ]; then ok "No forked clones found — this monorepo is already fork-free. Nothing to do."; exit 0; fi

# ─────────────────────────────────── Phase 0: report ────────────────────────────────────────
hdr "Report — $tmpCount forked module clone(s) to clean"
declare -a RISK_AHEAD RISK_DIRTY
printf '%s\n' "  ${C_DIM}module                         fork-owner        risk${C_RESET}"
for i in "${!FORK_DIRS[@]}"; do
	tmpDir="${FORK_DIRS[$i]}"; tmpName="${FORK_NAMES[$i]}"; tmpOwner="${FORK_OWNERS[$i]}"
	tmpRisk=""
	# dirty working tree?
	if [ -n "$(git -C "$tmpDir" status --porcelain 2>/dev/null)" ]; then tmpRisk="dirty-tree"; RISK_DIRTY+=("$tmpName"); fi
	# fork ahead of canonical? best-effort: compare origin/HEAD..HEAD-branch vs canonical (via upstream if present)
	tmpBranch="$(git -C "$tmpDir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
	tmpAhead=""
	if git -C "$tmpDir" remote get-url upstream >/dev/null 2>&1; then
		tmpAhead="$(git -C "$tmpDir" rev-list --count "upstream/$tmpBranch..$tmpBranch" 2>/dev/null || echo '')"
	fi
	if [ -n "$tmpAhead" ] && [ "$tmpAhead" != "0" ]; then
		tmpRisk="${tmpRisk:+$tmpRisk, }ahead-of-canonical:$tmpAhead"; RISK_AHEAD+=("$tmpName")
	fi
	printf '  %-30s %-17s %s\n' "$tmpName" "$tmpOwner" "${tmpRisk:+${C_YELLOW}$tmpRisk${C_RESET}}"
done
[ "${#RISK_AHEAD[@]}" -gt 0 ] && warn "  ⚠ ${#RISK_AHEAD[@]} fork(s) MAY be ahead of canonical: ${RISK_AHEAD[*]}"
[ "${#RISK_DIRTY[@]}" -gt 0 ] && warn "  ⚠ ${#RISK_DIRTY[@]} clone(s) have a DIRTY working tree: ${RISK_DIRTY[*]}"
info "  (Ahead is a fast best-effort estimate from the local 'upstream' ref — it can over-report if that"
info "   ref is stale. Deletion re-verifies each fork against a FRESH canonical fetch and skips any that"
info "   are genuinely ahead. The backup step also bundles ALL refs, so nothing is lost regardless.)"

if [ "$DRY_RUN" = 1 ]; then hdr "Dry-run complete."; info "Re-run without --dry-run to act on the gates."; exit 0; fi
if ! gate "Proceed with cleanup of the $tmpCount module(s) above?"; then say "Aborted — no changes made."; exit 0; fi

# ─────────────────────────── Phase 1: backup every ref to ~/Tmp ──────────────────────────────
if [ "$DO_BACKUP" = 1 ]; then
	hdr "Backup — bundling every ref to $BACKUP_DIR"
	mkdir -p "$BACKUP_DIR"
	for i in "${!FORK_DIRS[@]}"; do
		tmpDir="${FORK_DIRS[$i]}"; tmpName="${FORK_NAMES[$i]}"
		if [ -f "$BACKUP_DIR/$tmpName.bundle" ]; then info "  $tmpName — already backed up, skipping"; continue; fi
		if git -C "$tmpDir" bundle create "$BACKUP_DIR/$tmpName.bundle" --all >/dev/null 2>&1; then
			git -C "$tmpDir" remote -v > "$BACKUP_DIR/$tmpName.remotes.txt" 2>/dev/null
			ok "  $tmpName — bundled ($(du -h "$BACKUP_DIR/$tmpName.bundle" | cut -f1))"
		else
			err "  $tmpName — BUNDLE FAILED; it will be skipped for fork deletion."
			FORK_OWNERS[$i]="__BACKUP_FAILED__"
		fi
	done
	info "  Restore any module later with:  git clone $BACKUP_DIR/<name>.bundle <dir>"
else
	warn "Backup disabled (--no-backup)."
fi

# ─────────────────────────── Phase 2: re-point origin -> canonical ───────────────────────────
hdr "Re-point — origin -> $CANONICAL_ORG, drop upstream"
if gate "Re-point local remotes now?"; then
	for i in "${!FORK_DIRS[@]}"; do
		tmpDir="${FORK_DIRS[$i]}"; tmpName="${FORK_NAMES[$i]}"; tmpOrigin="${FORK_ORIGINS[$i]}"
		tmpNew="$(canonical_url "$tmpOrigin" "$tmpName")"
		git -C "$tmpDir" remote set-url origin "$tmpNew"
		git -C "$tmpDir" remote get-url upstream >/dev/null 2>&1 && git -C "$tmpDir" remote remove upstream
		git -C "$tmpDir" fetch origin --quiet 2>/dev/null || true
		ok "  $tmpName — origin -> $tmpNew"
	done
else
	warn "Skipped re-point."
fi

# ─────────────────────────── Phase 3: delete the personal forks ─────────────────────────────
hdr "Delete forks — remove <owner>/<module> from GitHub (PERMANENT)"
if [ "$HAVE_GH" = 0 ]; then
	warn "gh CLI not authenticated — skipping fork deletion. Install/login with:  gh auth login  (needs delete_repo scope: gh auth refresh -s delete_repo)"
elif gate "Delete the personal GitHub forks now? This cannot be undone." "DELETE"; then
	for i in "${!FORK_DIRS[@]}"; do
		tmpDir="${FORK_DIRS[$i]}"; tmpName="${FORK_NAMES[$i]}"; tmpOwner="${FORK_OWNERS[$i]}"
		[ "$tmpOwner" = "__BACKUP_FAILED__" ] && { warn "  $tmpName — backup failed earlier; NOT deleting."; continue; }
		[ "$tmpOwner" = "$CANONICAL_ORG" ] && continue
		# idempotent: skip if the fork is already gone
		if ! gh repo view "$tmpOwner/$tmpName" >/dev/null 2>&1; then info "  $tmpOwner/$tmpName — already gone"; continue; fi
		# safety: FRESH-fetch canonical and refuse to delete if this clone has commits canonical lacks
		# (an accurate ff-check — does not trust the possibly-stale local 'upstream' ref). The bundle
		# backup in ~/Tmp still holds every ref regardless, so nothing is lost even with --force.
		tmpBranch="$(git -C "$tmpDir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
		if git -C "$tmpDir" fetch "https://github.com/$CANONICAL_ORG/$tmpName.git" "$tmpBranch" --quiet 2>/dev/null; then
			tmpForkAhead="$(git -C "$tmpDir" rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo '?')"
		else
			tmpForkAhead='?'   # couldn't verify — treat as risky
		fi
		if [ "$tmpForkAhead" != "0" ] && [ "$FORCE" = 0 ]; then
			warn "  $tmpOwner/$tmpName — $tmpForkAhead commit(s) ahead of canonical (or unverifiable); skipping. Land them first, or --force (refs are in the backup)."
			continue
		fi
		if gh repo delete "$tmpOwner/$tmpName" --yes >/dev/null 2>&1; then ok "  $tmpOwner/$tmpName — deleted"
		else err "  $tmpOwner/$tmpName — delete failed (needs 'delete_repo' scope? run: gh auth refresh -s delete_repo)"; fi
	done
else
	warn "Skipped fork deletion."
fi

# ─────────────────────── Phase 4: (optional) flip the manifest + regen ───────────────────────
if [ "$FLIP_MANIFEST" = 1 ]; then
	hdr "Manifest — set Forkable:false on every module + regenerate the shell list"
	warn "This edits the shared Retold-Modules-Manifest.json. It is a ONE-TIME canonical change:"
	warn "run it on ONE machine, commit + push, and have everyone else 'git pull' — don't commit it from five machines."
	if gate "Flip Forkable:false in the manifest now (local edit only; you commit)?"; then
		node -e '
			const fs=require("fs"); const p=process.argv[1];
			const m=JSON.parse(fs.readFileSync(p,"utf8")); let n=0;
			for (const g of (m.Groups||[])) for (const mod of (g.Modules||[])) {
				if (mod.Forkable !== false) { mod.Forkable = false; n++; }
			}
			fs.writeFileSync(p, JSON.stringify(m,null,"\t")+"\n");
			console.log("  set Forkable:false on "+n+" module(s)");
		' "$MONOREPO/Retold-Modules-Manifest.json"
		if [ -f "$MONOREPO/package.json" ] && grep -q '"rebuild-modules"' "$MONOREPO/package.json"; then
			( cd "$MONOREPO" && npm run --silent rebuild-modules >/dev/null 2>&1 ) && ok "  regenerated modules/Include-Retold-Module-List.sh"
		fi
		info "  Review + commit:  cd $MONOREPO && git add Retold-Modules-Manifest.json modules/Include-Retold-Module-List.sh && git commit -m 'Retire the fork model (Forkable:false)'"
	else
		warn "Skipped manifest flip."
	fi
fi

hdr "Done."
[ "$DO_BACKUP" = 1 ] && ok "Backups (git bundles of every ref) are in: $BACKUP_DIR"
ok "Re-run any time — it is idempotent (canonical clones + deleted forks are skipped)."
