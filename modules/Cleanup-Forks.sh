#!/usr/bin/env bash
#
# Cleanup-Forks.sh — retire the fork / upstream model across a retold synthetic monorepo.
#
# The old model: every "forkable" module was forked from the canonical org (fable-retold) to your
# personal GitHub account, cloned as origin=<you>/<module> with upstream=fable-retold. We're done with
# forks — modules now track local + remote (origin=fable-retold) + npm only.
#
# Two INDEPENDENT jobs, so it's safe to re-run and safe after a partial run:
#   RE-POINT  every local clone still on a fork  -> origin=fable-retold, drop `upstream`.  (local, on-disk)
#   DELETE    your personal GitHub forks.  Discovered from GitHub (gh repo list --fork), NOT from the
#             local origin — so it still finds them after re-pointing. Each fork is compared to canonical
#             first; a fork with commits canonical lacks is mirror-backed-up to ~/Tmp and then skipped
#             (unless --force). Idempotent: already-deleted forks are skipped.
#   UMBRELLA  the monorepo-root repo itself (e.g. your `retold` checkout) is re-pointed the same way
#             (origin -> canonical, drop `upstream`); its fork is offered for deletion LAST, behind a
#             separate `DELETE-UMBRELLA` gate — it's the repo other machines still pull from, so only
#             delete it once every machine has re-pointed. Reconcile/land local umbrella commits first.
#
# Runs per user/machine over whatever it has: the fork owner is your gh login, so you can delete every
# fork from ONE machine and just re-point on the others. Personal (Forkable:false) modules are never
# touched.
#
# Usage:  bash Cleanup-Forks.sh [MONOREPO_DIR]
# Flags:
#   --dry-run        report only; make no changes
#   --yes            accept every gate non-interactively (use with care)
#   --no-backup      skip the local-clone bundle backup (fork mirrors of ahead forks still happen)
#   --force          delete forks even if ahead of canonical (they are mirror-backed-up first)
#   --flip-manifest  also flip Forkable:false in the manifest + regenerate (ONE machine, ONE time)
#   BACKUP_DIR=...   override backup location (default: ~/Tmp/retold-fork-cleanup-<timestamp>)
#
set -o pipefail   # NOT `set -u`: macOS bash 3.2 errors on empty-array expansion under -u.

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

gate() {
	tmpPrompt="$1"; tmpExpect="${2:-yes}"
	if [ "$DRY_RUN" = "1" ]; then info "  (dry-run) would ask: $tmpPrompt"; return 1; fi
	if [ "$ASSUME_YES" = "1" ]; then return 0; fi
	tmpReply=""
	printf '%s ' "${C_BOLD}${tmpPrompt}${C_RESET} [type '${tmpExpect}']:"
	read -r tmpReply
	[ "$tmpReply" = "$tmpExpect" ]
}

# ────────────────────────────────────── locate monorepo ─────────────────────────────────────
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
	err "Could not find the retold monorepo. Run from inside it, or pass its path: bash Cleanup-Forks.sh /path/to/retold"
	exit 1
fi
MONOREPO="$(cd "$MONOREPO" && pwd)"

CANONICAL_ORG="$CANONICAL_ORG_DEFAULT"
if [ -f "$MONOREPO/modules/Include-Retold-Module-List.sh" ]; then
	tmpOrg="$(grep -E '^canonicalOrg=' "$MONOREPO/modules/Include-Retold-Module-List.sh" | head -1 | sed -E 's/.*="?([^"]+)"?.*/\1/')"
	[ -n "$tmpOrg" ] && CANONICAL_ORG="$tmpOrg"
fi

command -v node >/dev/null 2>&1 || { err "node is required (to read the manifest's Forkable flags)."; exit 1; }
HAVE_GH=0; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && HAVE_GH=1

# fork owner = your gh login (the account your forks live under). Fallback: an origin off canonical.
FORK_OWNER=""
[ "$HAVE_GH" = 1 ] && FORK_OWNER="$(gh api user --jq .login 2>/dev/null)"
if [ -z "$FORK_OWNER" ]; then
	FORK_OWNER="$(find "$MONOREPO/modules" -mindepth 3 -maxdepth 3 -name .git 2>/dev/null | while IFS= read -r g; do
		u="$(git -C "$(dirname "$g")" remote get-url origin 2>/dev/null | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+)/.*#\2#')"
		[ -n "$u" ] && [ "$u" != "$CANONICAL_ORG" ] && { echo "$u"; break; }; done | head -1)"
fi

hdr "retold fork cleanup"
info "monorepo:      $MONOREPO"
info "canonical org: $CANONICAL_ORG"
info "fork owner:    ${FORK_OWNER:-<unknown>}"
info "backup dir:    $BACKUP_DIR $([ "$DO_BACKUP" = 0 ] && echo '(clone backup disabled; fork mirrors still made)')"
info "gh available:  $([ "$HAVE_GH" = 1 ] && echo yes || echo 'no — fork deletion will be skipped')"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN — no changes will be made."
if [ -n "$FORK_OWNER" ] && [ "$FORK_OWNER" = "$CANONICAL_ORG" ]; then err "fork owner == canonical org; refusing to run."; exit 1; fi

url_owner() { printf '%s' "$1" | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+)/.*#\2#'; }

# forkable set from the manifest (Forkable !== false). The ONLY modules we ever touch.
FORKABLE_NAMES=" $(node -e '
	const m=require(process.argv[1]); const out=[];
	for (const g of (m.Groups||[])) for (const mod of (g.Modules||[]))
		if (mod.Forkable !== false && mod.Forkable !== 0 && mod.Forkable !== "0") out.push(mod.Name);
	process.stdout.write(out.join(" "));
' "$MONOREPO/Retold-Modules-Manifest.json") "
is_forkable() { case "$FORKABLE_NAMES" in *" $1 "*) return 0;; *) return 1;; esac; }

# ───────────────── discover: (A) clones to re-point   (B) forks to delete ─────────────────
# (A) on-disk forkable clones whose origin drifted off canonical → need re-pointing.
REPOINT_DIRS=(); REPOINT_NAMES=(); REPOINT_ORIGINS=(); tmpSkipped=0
while IFS= read -r tmpGitDir; do
	tmpDir="$(dirname "$tmpGitDir")"; tmpName="$(basename "$tmpDir")"
	tmpOrigin="$(git -C "$tmpDir" remote get-url origin 2>/dev/null)"
	[ -z "$tmpOrigin" ] && continue
	printf '%s' "$tmpOrigin" | grep -q 'github\.com' || continue
	[ "$(url_owner "$tmpOrigin")" = "$CANONICAL_ORG" ] && continue
	is_forkable "$tmpName" || { tmpSkipped=$((tmpSkipped+1)); continue; }
	REPOINT_DIRS+=("$tmpDir"); REPOINT_NAMES+=("$tmpName"); REPOINT_ORIGINS+=("$tmpOrigin")
done < <(find "$MONOREPO/modules" -mindepth 3 -maxdepth 3 -name .git 2>/dev/null | sort)
[ "$tmpSkipped" -gt 0 ] && info "($tmpSkipped non-forkable / personal clone(s) off canonical left untouched.)"

# (B) your GitHub forks (forkable) — from GitHub, so this survives re-pointing.
DELETE_NAMES=(); DELETE_BRANCHES=()
if [ "$HAVE_GH" = 1 ] && [ -n "$FORK_OWNER" ]; then
	while IFS=$'\t' read -r tmpN tmpB; do
		[ -z "$tmpN" ] && continue
		is_forkable "$tmpN" || continue
		DELETE_NAMES+=("$tmpN"); DELETE_BRANCHES+=("${tmpB:-main}")
	done < <(gh repo list "$FORK_OWNER" --fork --limit 1000 --json name,defaultBranchRef \
		--jq '.[] | [.name, (.defaultBranchRef.name // "main")] | @tsv' 2>/dev/null | sort)
fi

# (C) the umbrella repo itself (the monorepo root) — retire the fork model here too.
UMBRELLA_DIR=""; UMBRELLA_ORIGIN=""; UMBRELLA_REPO=""; UMBRELLA_TARGET=""; UMBRELLA_HASUP=0
if git -C "$MONOREPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	tmpUO="$(git -C "$MONOREPO" remote get-url origin 2>/dev/null)"
	if printf '%s' "$tmpUO" | grep -q 'github\.com' && [ "$(url_owner "$tmpUO")" != "$CANONICAL_ORG" ]; then
		UMBRELLA_DIR="$MONOREPO"; UMBRELLA_ORIGIN="$tmpUO"; UMBRELLA_REPO="$(basename "$tmpUO" .git)"
		UMBRELLA_TARGET="https://github.com/$CANONICAL_ORG/$UMBRELLA_REPO.git"
		printf '%s' "$tmpUO" | grep -q '^git@' && UMBRELLA_TARGET="git@github.com:$CANONICAL_ORG/$UMBRELLA_REPO.git"
		git -C "$MONOREPO" remote get-url upstream >/dev/null 2>&1 && UMBRELLA_HASUP=1
	fi
fi

if [ "${#REPOINT_DIRS[@]}" -eq 0 ] && [ "${#DELETE_NAMES[@]}" -eq 0 ] && [ -z "$UMBRELLA_DIR" ]; then
	ok "Nothing to do — no forkable clones off canonical and no forkable forks on your account. Already clean."
	exit 0
fi

# ─────────────────────────────────────── report ────────────────────────────────────────
hdr "Report"
say "  ${C_BOLD}Re-point${C_RESET} (local clones still on a fork → $CANONICAL_ORG): ${#REPOINT_DIRS[@]}"
for i in "${!REPOINT_NAMES[@]}"; do
	tmpDirty=""; [ -n "$(git -C "${REPOINT_DIRS[$i]}" status --porcelain 2>/dev/null)" ] && tmpDirty=" ${C_YELLOW}(dirty — commit first; see Commit-Dirty.sh)${C_RESET}"
	printf '    %-34s %s%s\n' "${REPOINT_NAMES[$i]}" "$(url_owner "${REPOINT_ORIGINS[$i]}")" "$tmpDirty"
done
if [ -n "$UMBRELLA_DIR" ]; then
	tmpUd=""; [ -n "$(git -C "$UMBRELLA_DIR" status --porcelain 2>/dev/null)" ] && tmpUd=" ${C_YELLOW}(dirty — commit first)${C_RESET}"
	say "  ${C_BOLD}Re-point umbrella${C_RESET} ($UMBRELLA_REPO: $(url_owner "$UMBRELLA_ORIGIN") → $CANONICAL_ORG$([ "$UMBRELLA_HASUP" = 1 ] && printf '%s' ', drop upstream'))$tmpUd"
fi
say "  ${C_BOLD}Delete${C_RESET} (your GitHub forks under $FORK_OWNER → removed): ${#DELETE_NAMES[@]}"
DELETE_AHEAD=()   # per-index cache (aligned with DELETE_NAMES) so the delete loop doesn't re-compare
if [ "${#DELETE_NAMES[@]}" -gt 0 ]; then
	info "    (comparing each fork to canonical — one API call per fork; ahead forks are backed up + skipped unless --force)"
	AHEAD_NAMES=(); tmpTotal="${#DELETE_NAMES[@]}"
	for i in "${!DELETE_NAMES[@]}"; do
		tmpN="${DELETE_NAMES[$i]}"; tmpB="${DELETE_BRANCHES[$i]}"
		[ -t 1 ] && printf '\r    comparing %d/%d … %-34s' "$((i+1))" "$tmpTotal" "$tmpN"
		tmpAhead="$(gh api "repos/$FORK_OWNER/$tmpN/compare/$CANONICAL_ORG:$tmpB...$tmpB" --jq '.ahead_by' 2>/dev/null)"
		[ -z "$tmpAhead" ] && tmpAhead='?'
		DELETE_AHEAD[$i]="$tmpAhead"
		[ "$tmpAhead" != "0" ] && AHEAD_NAMES+=("$tmpN")
	done
	[ -t 1 ] && printf '\r%*s\r' 72 ''   # wipe the progress line before printing the summary
	for i in "${!DELETE_NAMES[@]}"; do
		[ "${DELETE_AHEAD[$i]}" != "0" ] && printf '    %-34s %s\n' "${DELETE_NAMES[$i]}" "${C_YELLOW}ahead of canonical: ${DELETE_AHEAD[$i]}${C_RESET}"
	done
	[ "${#AHEAD_NAMES[@]}" -gt 0 ] && warn "    ⚠ ${#AHEAD_NAMES[@]} fork(s) are AHEAD of canonical — mirror-backed-up then skipped (unless --force): ${AHEAD_NAMES[*]}"
fi

if [ "$DRY_RUN" = 1 ]; then hdr "Dry-run complete — no changes made."; exit 0; fi
if ! gate "Proceed?"; then say "Aborted — no changes made."; exit 0; fi

# ─────────────────────── re-point (with a local-clone bundle backup) ───────────────────────
if [ "${#REPOINT_DIRS[@]}" -gt 0 ]; then
	hdr "Re-point — origin → $CANONICAL_ORG, drop upstream"
	if gate "Re-point ${#REPOINT_DIRS[@]} local clone(s) now?"; then
		[ "$DO_BACKUP" = 1 ] && mkdir -p "$BACKUP_DIR"
		for i in "${!REPOINT_DIRS[@]}"; do
			tmpDir="${REPOINT_DIRS[$i]}"; tmpName="${REPOINT_NAMES[$i]}"; tmpOrigin="${REPOINT_ORIGINS[$i]}"
			if [ "$DO_BACKUP" = 1 ] && [ ! -f "$BACKUP_DIR/$tmpName.bundle" ]; then
				git -C "$tmpDir" bundle create "$BACKUP_DIR/$tmpName.bundle" --all >/dev/null 2>&1 && git -C "$tmpDir" remote -v > "$BACKUP_DIR/$tmpName.remotes.txt" 2>/dev/null
			fi
			tmpNew="https://github.com/$CANONICAL_ORG/$tmpName.git"
			printf '%s' "$tmpOrigin" | grep -q '^git@' && tmpNew="git@github.com:$CANONICAL_ORG/$tmpName.git"
			git -C "$tmpDir" remote set-url origin "$tmpNew"
			git -C "$tmpDir" remote get-url upstream >/dev/null 2>&1 && git -C "$tmpDir" remote remove upstream
			ok "  $tmpName — origin → $tmpNew"
		done
	else warn "Skipped re-point."; fi
fi

# ── umbrella repo (the monorepo root itself) ──
if [ -n "$UMBRELLA_DIR" ]; then
	hdr "Re-point umbrella — $UMBRELLA_REPO origin → $CANONICAL_ORG$([ "$UMBRELLA_HASUP" = 1 ] && printf '%s' ', drop upstream')"
	if gate "Re-point the umbrella repo ($UMBRELLA_REPO) now?"; then
		if [ "$DO_BACKUP" = 1 ]; then
			mkdir -p "$BACKUP_DIR"
			[ -f "$BACKUP_DIR/$UMBRELLA_REPO.umbrella.bundle" ] || { git -C "$UMBRELLA_DIR" bundle create "$BACKUP_DIR/$UMBRELLA_REPO.umbrella.bundle" --all >/dev/null 2>&1 && git -C "$UMBRELLA_DIR" remote -v > "$BACKUP_DIR/$UMBRELLA_REPO.umbrella.remotes.txt" 2>/dev/null; }
		fi
		git -C "$UMBRELLA_DIR" remote set-url origin "$UMBRELLA_TARGET"
		[ "$UMBRELLA_HASUP" = 1 ] && git -C "$UMBRELLA_DIR" remote remove upstream 2>/dev/null
		ok "  $UMBRELLA_REPO — origin → $UMBRELLA_TARGET"
		# warn if the local branch carries commits not yet on the new canonical origin
		tmpBr="$(git -C "$UMBRELLA_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
		if git -C "$UMBRELLA_DIR" fetch --quiet origin "$tmpBr" 2>/dev/null; then
			tmpUAhead="$(git -C "$UMBRELLA_DIR" rev-list --count "origin/$tmpBr..$tmpBr" 2>/dev/null)"
			[ -n "$tmpUAhead" ] && [ "$tmpUAhead" -gt 0 ] && warn "  ⚠ $tmpUAhead local umbrella commit(s) not yet on $CANONICAL_ORG/$UMBRELLA_REPO — reconcile + push (git -C \"$UMBRELLA_DIR\" push origin $tmpBr) before deleting the fork."
		fi
	else warn "Skipped umbrella re-point."; fi
fi

# ─────────────────────────────── delete the personal forks ───────────────────────────────
if [ "${#DELETE_NAMES[@]}" -gt 0 ]; then
	hdr "Delete forks — remove $FORK_OWNER/<module> from GitHub (PERMANENT)"
	if [ "$HAVE_GH" = 0 ]; then warn "gh not authenticated — skipping."
	else
	gh auth status 2>&1 | grep -q 'delete_repo' || warn "  (note: 'delete_repo' scope not detected — if deletes fail with a 403, run: gh auth refresh -s delete_repo)"
	if gate "Delete ${#DELETE_NAMES[@]} personal fork(s)? This cannot be undone." "DELETE"; then
		mkdir -p "$BACKUP_DIR"
		for i in "${!DELETE_NAMES[@]}"; do
			tmpN="${DELETE_NAMES[$i]}"; tmpB="${DELETE_BRANCHES[$i]}"
			if ! gh repo view "$FORK_OWNER/$tmpN" >/dev/null 2>&1; then info "  $FORK_OWNER/$tmpN — already gone"; continue; fi
			tmpAhead="${DELETE_AHEAD[$i]:-?}"   # reuse the comparison computed in the report (no second API pass)
			if [ "$tmpAhead" != "0" ]; then
				# preserve the fork's unique commits before we consider deleting it
				[ -d "$BACKUP_DIR/$tmpN.fork.git" ] || git clone --mirror "https://github.com/$FORK_OWNER/$tmpN.git" "$BACKUP_DIR/$tmpN.fork.git" >/dev/null 2>&1
				if [ "$FORCE" = 0 ]; then
					warn "  $FORK_OWNER/$tmpN — ahead of canonical by $tmpAhead; mirror-backed-up to $BACKUP_DIR/$tmpN.fork.git; SKIPPING (use --force to delete)."
					continue
				fi
			fi
			if gh repo delete "$FORK_OWNER/$tmpN" --yes >/dev/null 2>&1; then ok "  $FORK_OWNER/$tmpN — deleted"
			else err "  $FORK_OWNER/$tmpN — delete failed"; fi
		done
	else warn "Skipped fork deletion."; fi
	fi
fi

# ── delete the umbrella fork (separate + last: it's the repo other machines still pull from) ──
if [ -n "$UMBRELLA_DIR" ] && [ "$HAVE_GH" = 1 ] && [ -n "$FORK_OWNER" ] && \
	gh repo view "$FORK_OWNER/$UMBRELLA_REPO" --json isFork --jq '.isFork' 2>/dev/null | grep -q true; then
	hdr "Delete umbrella fork — $FORK_OWNER/$UMBRELLA_REPO from GitHub (PERMANENT)"
	warn "  Do this LAST — only after every machine + colleague has re-pointed their umbrella origin to $CANONICAL_ORG (it's the repo they pull from)."
	tmpUB="$(gh api "repos/$FORK_OWNER/$UMBRELLA_REPO" --jq '.default_branch' 2>/dev/null)"; tmpUB="${tmpUB:-main}"
	tmpUAh="$(gh api "repos/$FORK_OWNER/$UMBRELLA_REPO/compare/$CANONICAL_ORG:$tmpUB...$tmpUB" --jq '.ahead_by' 2>/dev/null)"; [ -z "$tmpUAh" ] && tmpUAh='?'
	if [ "$tmpUAh" != "0" ]; then
		mkdir -p "$BACKUP_DIR"; [ -d "$BACKUP_DIR/$UMBRELLA_REPO.fork.git" ] || git clone --mirror "https://github.com/$FORK_OWNER/$UMBRELLA_REPO.git" "$BACKUP_DIR/$UMBRELLA_REPO.fork.git" >/dev/null 2>&1
		[ "$FORCE" = 0 ] && warn "  $FORK_OWNER/$UMBRELLA_REPO — ahead of canonical by $tmpUAh; mirror-backed-up; SKIPPING (reconcile/land it first, or --force)."
	fi
	if [ "$tmpUAh" = "0" ] || [ "$FORCE" = 1 ]; then
		if gate "Delete the umbrella fork $FORK_OWNER/$UMBRELLA_REPO? Irreversible + other machines pull from it." "DELETE-UMBRELLA"; then
			if gh repo delete "$FORK_OWNER/$UMBRELLA_REPO" --yes >/dev/null 2>&1; then ok "  $FORK_OWNER/$UMBRELLA_REPO — deleted"
			else err "  $FORK_OWNER/$UMBRELLA_REPO — delete failed"; fi
		else warn "  Skipped umbrella fork deletion."; fi
	fi
fi

# ─────────────────────── (optional) flip the manifest + regen ───────────────────────
if [ "$FLIP_MANIFEST" = 1 ]; then
	hdr "Manifest — set Forkable:false on every module + regenerate the shell list"
	warn "ONE-TIME canonical change: run on ONE machine, commit + push, everyone else 'git pull'."
	if gate "Flip Forkable:false in the manifest now (local edit only; you commit)?"; then
		node -e '
			const fs=require("fs"); const p=process.argv[1];
			const m=JSON.parse(fs.readFileSync(p,"utf8")); let n=0;
			for (const g of (m.Groups||[])) for (const mod of (g.Modules||[])) if (mod.Forkable !== false) { mod.Forkable = false; n++; }
			fs.writeFileSync(p, JSON.stringify(m,null,"\t")+"\n"); console.log("  set Forkable:false on "+n+" module(s)");
		' "$MONOREPO/Retold-Modules-Manifest.json"
		[ -f "$MONOREPO/package.json" ] && grep -q '"rebuild-modules"' "$MONOREPO/package.json" && \
			( cd "$MONOREPO" && npm run --silent rebuild-modules >/dev/null 2>&1 ) && ok "  regenerated modules/Include-Retold-Module-List.sh"
		info "  Review + commit:  cd $MONOREPO && git add Retold-Modules-Manifest.json modules/Include-Retold-Module-List.sh && git commit -m 'Retire the fork model (Forkable:false)'"
	else warn "Skipped manifest flip."; fi
fi

hdr "Done."
[ -d "$BACKUP_DIR" ] && ok "Backups are in: $BACKUP_DIR"
ok "Idempotent — re-run any time; re-pointed clones and deleted forks are skipped."
