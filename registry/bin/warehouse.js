#!/usr/bin/env node
/**
 * Warehouse seeder.
 *
 * Walks every package-lock.json under the given roots (default: the whole retold
 * monorepo), collects every registry tarball they reference, and pulls each one
 * THROUGH the running proxy so Verdaccio caches it into ./storage. After this runs,
 * ./storage is a complete offline mirror of the monorepo's dependency closure --
 * copy it to a drive and a sealed box installs with the uplink turned off.
 *
 * Lazy caching happens for free as you install; this makes it EAGER and complete,
 * so nothing is missing the day npm is down or a version gets unpublished.
 *
 * Usage:
 *   node bin/warehouse.js [rootDir ...]
 * Env:
 *   REGISTRY   proxy base URL (default http://localhost:4873)
 *   CONCURRENCY  parallel fetches (default 8)
 */

const libFS = require('fs');
const libPath = require('path');

const _REGISTRY = (process.env.REGISTRY || 'http://localhost:4873').replace(/\/+$/, '');
const _CONCURRENCY = Math.max(1, parseInt(process.env.CONCURRENCY || '8', 10));
// Default to the monorepo root (two levels up from registry/bin), so a bare run
// warehouses everything without arguments.
const _ROOTS = (process.argv.slice(2).length > 0)
	? process.argv.slice(2)
	: [ libPath.resolve(__dirname, '..', '..') ];

// Recursively find package-lock.json files, skipping the insides of node_modules
// (a package's own lock lives at its root; nested ones just duplicate coverage).
function findLockfiles(pRoot)
{
	let tmpFound = [];
	let tmpStack = [ pRoot ];
	while (tmpStack.length > 0)
	{
		let tmpDir = tmpStack.pop();
		let tmpEntries;
		try { tmpEntries = libFS.readdirSync(tmpDir, { withFileTypes: true }); }
		catch (pError) { continue; }
		for (let i = 0; i < tmpEntries.length; i++)
		{
			let tmpEntry = tmpEntries[i];
			if (tmpEntry.isDirectory())
			{
				if (tmpEntry.name === 'node_modules' || tmpEntry.name === '.git' || tmpEntry.name === 'storage') { continue; }
				tmpStack.push(libPath.join(tmpDir, tmpEntry.name));
			}
			else if (tmpEntry.name === 'package-lock.json')
			{
				tmpFound.push(libPath.join(tmpDir, tmpEntry.name));
			}
		}
	}
	return tmpFound;
}

// Every registry tarball URL a lock references (lockfile v2/v3 `packages`, and the
// legacy v1 `dependencies` tree). We key on the tarball URL itself, so the same
// name@version referenced by ten locks is fetched once.
function collectTarballs(pLockPath, pSet)
{
	let tmpLock;
	try { tmpLock = JSON.parse(libFS.readFileSync(pLockPath, 'utf8')); }
	catch (pError) { return; }

	let fConsider = (pResolved) =>
	{
		if (typeof pResolved !== 'string') { return; }
		if (!/^https?:\/\/registry\.npmjs\.org\//.test(pResolved)) { return; }
		if (!pResolved.endsWith('.tgz')) { return; }
		pSet.add(pResolved);
	};

	if (tmpLock.packages && typeof tmpLock.packages === 'object')
	{
		for (let tmpKey of Object.keys(tmpLock.packages))
		{
			fConsider(tmpLock.packages[tmpKey] && tmpLock.packages[tmpKey].resolved);
		}
	}
	let fWalkV1 = (pDeps) =>
	{
		if (!pDeps || typeof pDeps !== 'object') { return; }
		for (let tmpName of Object.keys(pDeps))
		{
			fConsider(pDeps[tmpName].resolved);
			fWalkV1(pDeps[tmpName].dependencies);
		}
	};
	fWalkV1(tmpLock.dependencies);
}

// Ask the proxy for the tarball by its path. Verdaccio fetches it from the uplink
// (if it hasn't already) and writes it into ./storage -- that GET is the warehousing.
async function warehouseOne(pResolved)
{
	let tmpPath = new URL(pResolved).pathname; // e.g. /fable/-/fable-3.1.79.tgz
	let tmpURL = _REGISTRY + tmpPath;
	try
	{
		let tmpResponse = await fetch(tmpURL, { method: 'GET' });
		// Drain the body so the connection completes and Verdaccio finishes writing.
		await tmpResponse.arrayBuffer();
		return tmpResponse.ok;
	}
	catch (pError)
	{
		return false;
	}
}

async function main()
{
	let tmpLocks = [];
	for (let tmpRoot of _ROOTS) { tmpLocks = tmpLocks.concat(findLockfiles(libPath.resolve(tmpRoot))); }
	console.log(`Warehouse: ${tmpLocks.length} lockfile(s) under ${_ROOTS.join(', ')}`);

	let tmpSet = new Set();
	for (let tmpLock of tmpLocks) { collectTarballs(tmpLock, tmpSet); }
	let tmpTarballs = [ ...tmpSet ];
	console.log(`Warehouse: ${tmpTarballs.length} unique registry tarball(s) to mirror into ./storage via ${_REGISTRY}`);

	let tmpOK = 0;
	let tmpFail = 0;
	let tmpIndex = 0;
	let tmpFailed = [];
	async function worker()
	{
		while (tmpIndex < tmpTarballs.length)
		{
			let tmpResolved = tmpTarballs[tmpIndex++];
			let tmpGood = await warehouseOne(tmpResolved);
			if (tmpGood) { tmpOK++; } else { tmpFail++; tmpFailed.push(tmpResolved); }
			if ((tmpOK + tmpFail) % 25 === 0 || (tmpOK + tmpFail) === tmpTarballs.length)
			{
				process.stdout.write(`\r  ${tmpOK + tmpFail}/${tmpTarballs.length}  (ok ${tmpOK}, fail ${tmpFail})   `);
			}
		}
	}
	await Promise.all(Array.from({ length: _CONCURRENCY }, () => worker()));
	process.stdout.write('\n');

	if (tmpFailed.length > 0)
	{
		console.log(`Warehouse: ${tmpFailed.length} failed (first few):`);
		tmpFailed.slice(0, 5).forEach((pURL) => console.log(`  - ${pURL}`));
	}
	console.log(`Warehouse: done -- ${tmpOK} cached, ${tmpFail} failed. ./storage is the mirror.`);
	process.exit(tmpFail > 0 ? 1 : 0);
}

main();
