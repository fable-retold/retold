# Retold appliance

One small Docker container that runs the two first-party Retold tools on an always-on box (a NAS or
Synology Diskstation), reachable from every machine on your tailnet by name:

- the local npm registry (Verdaccio) on port `4873`
- the monorepo manager web UI on port `44444`

The image is stateless. Everything that must persist (the module checkouts and the registry
warehouse) lives on one mounted `/data` volume, so you can rebuild or upgrade the image freely.

## Why it exists

Dev machines run the newest library code straight from local checkouts, but a remote node does a real
`npm install` and pulls whatever is published. When those differ, the node builds and deploys against
older code, which looks like the work getting reverted. This is publish debt.

The appliance closes it. The registry becomes the one place that holds the current versions: you
publish the bumped libraries into it, point every node's `.npmrc` at it, and now `npm install` on any
node resolves today's code instead of a stale copy. Private packages that never go to npmjs live here
too, so nodes get them without a checkout.

## What it needs

- Docker (DSM Container Manager on Synology).
- A shared folder with lots of disk, bind-mounted to `/data`. It holds the module checkouts and the
  warehouse, so size it for the full dependency closure plus the monorepo (tens of GB is comfortable).
- A read-only GitHub token for the private modules (see `.env.example`). Public modules need none.
- Tailscale on the NAS so it answers on a stable tailnet name.

## Deploy

1. Copy `.env.example` to `.env` and paste in your read-only `GH_TOKEN`.
2. Edit `docker-compose.yml`: point the volume's left side at your NAS folder (default `/volume1/retold`).
3. Bring it up:

   ```bash
   docker compose up -d --build
   ```

First boot is the slow one: it clones the umbrella repo, checks out every module it can see, and
builds the manager web UI once. That all caches under `/data`, so later boots come up quickly. Watch
progress with `docker compose logs -f`.

## Point your machines at it

On each machine (and in CI / on each node), set the registry in `.npmrc`:

```
registry=http://your-nas.tailnet.ts.net:4873/
```

Now `npm install` anywhere resolves through the appliance: current versions you have published in,
and a cached pull-through of npmjs for everything else.

## Feed it the current versions

Two ways to get today's code into the registry:

- Warehouse sync from a dev machine (serve-only): rsync your local warehouse onto the volume.

  ```bash
  rsync -a ~/Code/retold/registry/storage/  your-nas.tailnet.ts.net:/volume1/retold/registry/storage/
  ```

- Publish directly with `rnp` (this is how you close publish debt for a private or bumped package):

  ```bash
  rnp publish ~/Code/retold/modules/private/stacks --url http://your-nas.tailnet.ts.net:4873
  ```

## Browse the code

The manager web UI is at `http://your-nas.tailnet.ts.net:44444/`. It reads the checked-out modules on
the volume: status across every repo, package and dependency detail, and the run-only view for example
apps. It is read-only browsing here; it does not publish.

## Configuration

Set in `docker-compose.yml` (or the environment):

| Variable | Default | Meaning |
|---|---|---|
| `GH_TOKEN` | (none) | Read-only PAT for private-module checkout. Empty means public modules only. |
| `RETOLD_UMBRELLA_REPO` | `https://github.com/fable-retold/retold.git` | Umbrella repo to clone. |
| `RETOLD_UMBRELLA_BRANCH` | `master` | Umbrella branch to track. |
| `REGISTRY_PORT` | `4873` | Registry listen port. |
| `MANAGER_PORT` | `44444` | Manager web UI port. |

## Notes

- Do not commit `.env` or the warehouse. Both are gitignored here.
- The token is read-only on purpose: this box serves and browses, it does not publish on your behalf.
  When you later want it to be the master publish host, widen the token and add a publish step.
