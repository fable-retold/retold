# Retold Modules

This directory contains all Retold module groups. Each subfolder holds individual git repos.

## Module Management

Shell scripts manage all modules collectively:

- `Fork.sh` — Fork every forkable module from its canonical owner to your GitHub account (no-op for already-forked or non-forkable modules). Requires the `gh` CLI.
- `Checkout.sh` — Clone every module: forkable modules clone from `<your-user>/<module>` (with `upstream` set to the canonical owner for PR sync); non-forkable modules clone directly from their per-module Owner.
- `Install.sh` — Run `npm install` inside every cloned module so each module is runnable on its own (tests, examples, the per-module dev workflow). Pair this with `Checkout.sh` on a fresh box; the manager's per-module action buttons (`install`, `test`, `build`, `examples`, etc.) all assume each module has its own `node_modules/`.
- `Status.sh` — Show git status across all modules
- `Update.sh` — Pull with rebase across all modules (from each module's own `origin`). Also runs a fetch-only `git fetch upstream` on modules that have an `upstream` remote, so the manager's fork-vs-upstream drift counts refresh — without merging org commits into your tree (that stays behind `Sync-Upstream.sh`).
- `Fetch-Upstream.sh` — Fetch the `upstream` (org) remote for every forkable module without touching working trees. Refreshes the fork-vs-upstream drift counts the manager reads from `refs/remotes/upstream/*`.
- `Sync-Upstream.sh` — Pull upstream changes into every forkable fork: fetch upstream, rebase onto `upstream/<branch>`, then force-push (with lease) to the fork. Skips dirty modules and aborts (never force-pushes) on a rebase conflict; prints a done/skipped/failed summary.
- `Commit-Dirty.sh` — Commit uncommitted working-tree changes across module clones (run BEFORE `Cleanup-Forks.sh`, whose `~/Tmp` backup only bundles *committed* refs). For each dirty clone, shows the change and commits it with a message (per-module prompt, or `--message` for all; `--push` to push to origin). Portable + idempotent; `git add -A` respects `.gitignore`.
- `Cleanup-Forks.sh` — **One-time**: retire the fork model. For every forkable module you have checked out, re-points `origin` → the canonical org and drops the `upstream` remote, then (gated) deletes your personal GitHub fork. Discovers the monorepo, the canonical org, the forkable set (from the manifest), and each module's fork owner (from its own `origin`), so it's safe to hand to colleagues and run on any machine over any subset of modules. Idempotent; interactive gates you must accept; backs up every ref (`git bundle --all`) to `~/Tmp/` before touching anything; skips forks that are ahead of canonical (unless `--force`) and never touches `Forkable:false` (personal) modules. `--dry-run` reports only; `--flip-manifest` (one-time, one machine) flips `Forkable:false` across the manifest + regenerates the shell list.
- `Include-Retold-Module-List.sh` — Central registry (generated from `Retold-Modules-Manifest.json`) defining per-group parallel arrays: `repositoriesX`, `ownersX`, `forkableX`. Sourced by the scripts above.
- `Retold-Modules.md` — Human-readable module list with hosted doc links

Most modules are hosted at `github.com/fable-retold/<module-name>` (the canonical org). A small set lives at `github.com/stevenvelozo/<module-name>` and is marked `Forkable: false` in the manifest — these clone read-only.

## Module Groups

| Group | Folder | Count | Purpose |
|-------|--------|-------|---------|
| Fable | `fable/` | 6 | Core ecosystem, DI, config, logging |
| Meadow | `meadow/` | 13 | Data access, ORM, query DSL, schema |
| Orator | `orator/` | 6 | API server, Restify, proxy, WebSocket |
| Pict | `pict/` | 15 | MVC, views, templates, forms, TUI |
| Utility | `utility/` | 10+ | Build tools, manifests, docs |
| Apps | `apps/` | 2 | Full-stack applications built on Retold |

## Working in a Module

Each module has its own `package.json`, tests, and README.

**Testing:**
```bash
npm test                        # Mocha TDD: npx mocha -u tdd -R spec
npm run coverage                # nyc coverage report
```

**Building:**
```bash
npx quack build                 # Most modules use Quackage
```

Some modules (e.g., Pict, Fable) also use Gulp + Browserify for browser bundles.

## Code Style

- Tabs for indentation, never spaces
- Plain JavaScript only — no TypeScript
- Opening braces on new lines (Allman style)
- Variable naming:
  - `pVariable` — function parameters
  - `tmpVariable` — scoped/temporary variables
  - `VARIABLE` — globals and constants
  - `libSomeLibrary` — imported/required libraries
- Match existing patterns in whichever module you are editing

## Adding a New Module

1. Add the repo name to the appropriate array in `Include-Retold-Module-List.sh`
2. Update `Retold-Modules.md`
3. The module should follow the same structure: `package.json`, `source/`, `test/`, Mocha TDD tests
