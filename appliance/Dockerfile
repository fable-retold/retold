# Retold monorepo appliance
#
# One prebaked image that runs BOTH first-party tools side by side on an always-on box
# (a NAS / Synology Diskstation, reachable over the tailnet by name):
#
#   * the local npm registry  (Verdaccio)                 -> port 4873
#   * the monorepo manager    (retold-monorepo-manager)   -> port 44444
#
# Only Verdaccio is installed from npmjs. The two Retold tools are NOT on npm, so they run from
# the umbrella checkout the entrypoint clones at runtime -- which also means the appliance always
# tracks whatever is on the umbrella branch, with no publish step in the loop.
#
# All state (the module checkouts and the registry warehouse) lives on a mounted /data volume, so
# the image itself is stateless and disposable: rebuild or upgrade it without losing a thing.

FROM node:22-bookworm-slim

# git    : the read-only module checkout (Checkout.sh)
# gh     : Checkout.sh identifies the user and probes private-repo visibility with it
# tini   : correct PID-1 signal handling for the two long-running services
# rsync  : so a dev machine can push its warehouse into /data/registry/storage
# ca-certificates : https to github.com and npmjs
RUN apt-get update \
	&& apt-get install -y --no-install-recommends git ca-certificates tini rsync curl gnupg \
	&& mkdir -p -m 755 /etc/apt/keyrings \
	&& curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends gh \
	&& rm -rf /var/lib/apt/lists/* \
	&& npm install -g verdaccio@^5

COPY entrypoint.sh /usr/local/bin/retold-appliance
COPY registry.config.yaml /etc/retold/registry.config.yaml
RUN chmod +x /usr/local/bin/retold-appliance

# 4873 = npm registry (serve + pull-through), 44444 = monorepo manager web UI.
EXPOSE 4873 44444

# Everything that must survive a container replacement lives here. Mount a big-disk folder to it.
VOLUME ["/data"]

ENV RETOLD_DATA=/data \
	RETOLD_UMBRELLA_REPO=https://github.com/fable-retold/retold.git \
	RETOLD_UMBRELLA_BRANCH=master \
	REGISTRY_PORT=4873 \
	MANAGER_PORT=44444

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/retold-appliance"]
