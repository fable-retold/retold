#!/usr/bin/env bash
#
# Retold appliance entrypoint.
#
# Boot sequence, all idempotent and all writing under $RETOLD_DATA:
#   1. wire git + gh to a read-only GitHub token (private modules)
#   2. clone-or-fast-forward the umbrella repo (the manifest + Checkout.sh live here)
#   3. check out every module the manifest lists (probe-then-clone skips repos you cannot see)
#   4. build the manager web UI once (its dist/ is gitignored, so a fresh checkout has none)
#   5. run the registry and the manager side by side; if either dies, exit so Docker restarts us
#
set -uo pipefail

DATA="${RETOLD_DATA:-/data}"
REPO="${RETOLD_UMBRELLA_REPO:-https://github.com/fable-retold/retold.git}"
BRANCH="${RETOLD_UMBRELLA_BRANCH:-master}"
REG_PORT="${REGISTRY_PORT:-4873}"
MGR_PORT="${MANAGER_PORT:-44444}"

UMBRELLA="$DATA/retold"
STORAGE="$DATA/registry/storage"
MGR="$UMBRELLA/modules/apps/retold-monorepo-manager"
MANIFEST="$UMBRELLA/Retold-Modules-Manifest.json"

log() { echo "[appliance] $*"; }

mkdir -p "$DATA" "$STORAGE"

# --- 1. read-only GitHub auth ------------------------------------------------
# GH_TOKEN is a read-only fine-grained PAT (Contents: Read) covering fable-retold (public) plus the
# private stevenvelozo foundation repos. git uses it for every github.com clone; gh uses it directly.
if [ -n "${GH_TOKEN:-}" ]; then
	git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
	export GH_TOKEN
	log "GitHub token configured: private modules you can see will be cloned."
else
	log "No GH_TOKEN set: public modules only; private repos are skipped."
fi
git config --global --add safe.directory '*'
# NAS / network shares frequently drop the POSIX executable bit, so with git's default core.fileMode
# every checked-out script and binary (mode 100755 -> 100644) would show up as "modified." Ignore
# file-mode changes so a fresh checkout stays clean.
git config --global core.fileMode false

# --- 2. umbrella: clone or fast-forward --------------------------------------
if [ -d "$UMBRELLA/.git" ]; then
	log "Fast-forwarding umbrella checkout ($BRANCH)..."
	git -C "$UMBRELLA" fetch --quiet origin "$BRANCH" || log "umbrella fetch failed (offline?); using what is on disk."
	git -C "$UMBRELLA" checkout --quiet "$BRANCH" 2>/dev/null || true
	git -C "$UMBRELLA" merge --ff-only --quiet "origin/$BRANCH" 2>/dev/null || log "umbrella not fast-forwardable; leaving as-is."
else
	log "Cloning umbrella $REPO ($BRANCH)..."
	git clone --branch "$BRANCH" "$REPO" "$UMBRELLA" || { log "FATAL: could not clone the umbrella repo."; exit 1; }
fi

# --- 3. modules: clone anything missing --------------------------------------
# Checkout.sh clones only what is absent, and (for the Optional/private group) probes visibility with
# gh first -- so a token that cannot see a repo means a clean skip, not a failure.
if [ -f "$UMBRELLA/modules/Checkout.sh" ]; then
	log "Checking out modules (missing ones only)..."
	( cd "$UMBRELLA/modules" && bash ./Checkout.sh ) || log "Checkout.sh returned non-zero (optional/private repos skipped) -- continuing."
else
	log "modules/Checkout.sh not found; skipping module checkout."
fi

# --- 4. build the manager web UI once ----------------------------------------
if [ -d "$MGR" ]; then
	if [ ! -d "$MGR/node_modules" ] || [ ! -f "$MGR/webinterface/dist/index.html" ]; then
		log "Building the manager web UI (first run; this is the slow one)..."
		( cd "$MGR" && npm install --no-audit --no-fund && npm run build ) \
			|| log "manager build failed -- the registry will still run; the web UI may be unavailable."
	fi
else
	log "monorepo-manager checkout absent; the registry will run without the web UI."
fi

# --- 5. run both services ----------------------------------------------------
log "Starting npm registry on :$REG_PORT (serving $STORAGE)..."
verdaccio --config /etc/retold/registry.config.yaml --listen "0.0.0.0:$REG_PORT" &
REG_PID=$!

MGR_PID=""
if [ -f "$MGR/source/cli/MonorepoManager-Run.cjs" ] && [ -f "$MANIFEST" ]; then
	log "Starting monorepo manager on :$MGR_PORT..."
	node "$MGR/source/cli/MonorepoManager-Run.cjs" web --manifest "$MANIFEST" --host 0.0.0.0 --port "$MGR_PORT" &
	MGR_PID=$!
else
	log "Manager entry or manifest missing; running registry-only."
fi

log "Up.  registry :$REG_PORT   manager :${MGR_PID:+$MGR_PORT}${MGR_PID:-(disabled)}"

# Exit as soon as either service stops, so Docker's restart policy brings the whole thing back clean.
wait -n $REG_PID ${MGR_PID:-}
log "A service exited; shutting down so Docker can restart the container."
kill $REG_PID ${MGR_PID:-} 2>/dev/null || true
exit 1
