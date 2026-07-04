#!/usr/bin/env node
/**
 * npx manager — launcher for the standalone Monorepo Manager app.
 *
 * The old retold/source manager is retired: this shim boots the generic
 * retold-monorepo-manager app (modules/apps/retold-monorepo-manager) against
 * THIS monorepo, cloning + preparing it on first run so a fresh `git pull`
 * on any machine gives you a working `npx manager`.
 *
 * It will, as needed:
 *   1. clone the app from fable-retold if it isn't checked out,
 *   2. `npm install` its dependencies on first run,
 *   3. build the web bundle (the app repo doesn't commit webinterface/dist),
 *   4. derive the v2 Modules-Manifest.json from the umbrella's Retold-Modules-Manifest.json,
 *   5. launch: `npx manager` → web UI on 44444 (auto-open); `npx manager <verb…>` → forwarded to the CLI.
 */
const libPath = require('path');
const libFs = require('fs');
const libChildProcess = require('child_process');

const ROOT = libPath.resolve(__dirname, '..');                                     // umbrella root
const APP_DIR = libPath.join(ROOT, 'modules', 'apps', 'retold-monorepo-manager');
const APP_REPO = 'https://github.com/fable-retold/retold-monorepo-manager.git';
const APP_CLI = libPath.join(APP_DIR, 'source', 'cli', 'MonorepoManager-Run.cjs');
const LEGACY_MANIFEST = libPath.join(ROOT, 'Retold-Modules-Manifest.json');
const V2_MANIFEST = libPath.join(ROOT, 'Modules-Manifest.json');
const DIST_DIR = libPath.join(APP_DIR, 'webinterface', 'dist');

function step(pMessage) { console.log('  [manager] ' + pMessage); }
function fail(pMessage) { console.error('  [manager] ' + pMessage); process.exit(1); }
function runSync(pCommand, pArgs, pOptions) { return libChildProcess.spawnSync(pCommand, pArgs, Object.assign({ stdio: 'inherit' }, pOptions || {})); }

function printUsage()
{
	console.log('npx manager                 Start the Monorepo Manager web UI (port 44444, auto-opens).');
	console.log('npx manager <verb> [...]    Run a Monorepo Manager CLI verb (status, show, health, bulk, …).');
	console.log('');
	console.log('Web options:  --port <N>   --host <ADDR>   --no-open (don\'t open a browser)');
	console.log('First run clones + builds the app under modules/apps/retold-monorepo-manager.');
}

const tmpArgv = process.argv.slice(2);
// The verb is the first bare token that isn't the VALUE of a value-taking flag
// (so `--port 44471` doesn't mistake 44471 for a verb).
function detectVerb(pArgv)
{
	const tmpValueFlags = { '--port': 1, '--host': 1, '-m': 1, '--manifest': 1 };
	for (let i = 0; i < pArgv.length; i++)
	{
		const a = pArgv[i];
		if (a.startsWith('-')) { if (tmpValueFlags[a]) { i++; } continue; }
		return a;
	}
	return undefined;
}
const tmpFirstVerb = detectVerb(tmpArgv);
const tmpWantsHelp = tmpArgv.includes('--help') || tmpArgv.includes('-h');
if (!tmpFirstVerb && tmpWantsHelp) { printUsage(); process.exit(0); }
const tmpIsWeb = !tmpFirstVerb || tmpFirstVerb === 'web';

// ── 1. app checked out? ───────────────────────────────────────────
if (!libFs.existsSync(APP_CLI))
{
	step('app not found at modules/apps/retold-monorepo-manager — cloning ' + APP_REPO + ' …');
	if (runSync('git', ['clone', APP_REPO, APP_DIR]).status !== 0 || !libFs.existsSync(APP_CLI))
	{
		fail('clone failed — check your network and that ' + APP_REPO + ' is reachable.');
	}
}

// ── 2. dependencies installed? ────────────────────────────────────
if (!libFs.existsSync(libPath.join(APP_DIR, 'node_modules')))
{
	step('installing app dependencies (first run — this can take a minute) …');
	if (runSync('npm', ['install'], { cwd: APP_DIR }).status !== 0) { fail('npm install failed in ' + APP_DIR); }
}

// ── 3. web bundle built? (only needed for the web UI) ─────────────
function hasBundle() { try { return libFs.readdirSync(DIST_DIR).some((f) => f.endsWith('.js')); } catch (pError) { return false; } }
if (tmpIsWeb && !hasBundle())
{
	step('building the web interface (first run) …');
	if (runSync('npm', ['run', 'build'], { cwd: APP_DIR }).status !== 0) { fail('web build failed (npm run build in ' + APP_DIR + ').'); }
}

// ── 4. derive the v2 manifest from the umbrella's legacy manifest ──
if (libFs.existsSync(LEGACY_MANIFEST))
{
	const tmpStale = !libFs.existsSync(V2_MANIFEST) ||
		libFs.statSync(LEGACY_MANIFEST).mtimeMs > libFs.statSync(V2_MANIFEST).mtimeMs;
	if (tmpStale)
	{
		step('generating Modules-Manifest.json from Retold-Modules-Manifest.json …');
		runSync('node', [APP_CLI, 'manifest', 'migrate', '--input', LEGACY_MANIFEST, '--output', V2_MANIFEST], { cwd: ROOT });
	}
}

// ── 5. launch (cwd = ROOT so the app finds Modules-Manifest.json by upward search) ──
let tmpAppArgs;
if (tmpIsWeb)
{
	// mirror the old `npx manager`: auto-open unless --no-open; pass --port/--host through
	const tmpPass = [];
	let tmpOpen = true;
	for (let i = 0; i < tmpArgv.length; i++)
	{
		const a = tmpArgv[i];
		if (a === 'web') { continue; }
		if (a === '--no-open') { tmpOpen = false; continue; }
		if (a === '--open') { tmpOpen = true; continue; }
		if (a === '--port' || a === '--host') { tmpPass.push(a, tmpArgv[++i]); continue; }
		tmpPass.push(a);
	}
	tmpAppArgs = ['web'].concat(tmpPass);
	if (tmpOpen) { tmpAppArgs.push('--open'); }
}
else
{
	tmpAppArgs = tmpArgv.slice();
}

const tmpResult = runSync('node', [APP_CLI].concat(tmpAppArgs), { cwd: ROOT });
process.exit(tmpResult.status == null ? 0 : tmpResult.status);
