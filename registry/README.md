# Retold Registry

A local npm registry and pull-through cache for the retold monorepo, built on
Verdaccio. It does two jobs:

1. **Hosts the private retold packages** so modules consume each other as ordinary
   caret dependencies (`retold-application-foundation-server@^0.0.1`) instead of
   `npm link` symlinks or `file:` paths. A consuming module never knows whether a
   dependency came from here or from npmjs.
2. **Warehouses every tarball** the monorepo ever references. On a cache miss it
   fetches from npmjs and keeps the tarball in `./storage` forever. Copy `./storage`
   to a drive and a sealed, offline box installs the whole tree without ever
   reaching the internet.

No enterprise npm, no accounts, no token dance. That whole class of pain is the
thing this exists to avoid.

## Run it

Direct:

```bash
npm install       # first time only, pulls Verdaccio in
npm start         # serves on http://localhost:4873
```

Or in docker (same config, same `./storage` on disk -- the two are interchangeable):

```bash
docker compose up -d
docker compose down
```

## Point npm at it

Unscoped means the whole registry is redirected -- copy `.npmrc.example` to a
project (or your `~/.npmrc`):

```
registry=http://localhost:4873/
```

Everything installs local-first: retold packages come from the warehouse, public
packages proxy through and get cached. Stop the registry and drop that line to fall
back to vanilla npm.

## Warehouse the whole tree

With the registry running:

```bash
npm run warehouse        # walks every package-lock.json under retold/ and mirrors it
```

`./storage` is now a complete offline mirror. It is gitignored on purpose -- it is a
rebuildable/portable artifact, not source. Regenerate it any time from the lockfiles,
or carry it around.

## Air-gap

For a machine that must never touch the internet, remove the `npmjs` uplink from the
`proxy:` rule in `config.yaml` (or just run it offline). It then serves only what is
in `./storage`, and a genuine miss fails loudly -- which is what you want in a vault.

## Control

This folder is self-sufficient: `npm start` / `docker compose up` is all it needs.
A separate `retold-npm-proxy` CLI tool wraps start/stop/status/warehouse and handles
publishing the `private: true` retold packages into it; each works without the other.
