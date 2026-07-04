#!/usr/bin/env node
/**
 * Retired entry point. The old Retold Manager web server has been replaced by the standalone
 * Monorepo Manager app (modules/apps/retold-monorepo-manager). This file now delegates to the
 * launcher so that any `node_modules/.bin/manager` symlink created before the bin was repointed
 * still boots the new app. Safe to remove once every machine has re-run `npm install`.
 */
require('./manager-launch.js');
