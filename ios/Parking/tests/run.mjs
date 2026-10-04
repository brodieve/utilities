#!/usr/bin/env node
//
// run.mjs
//
// Runs the app's pass10x.js against the live Pass10x site in Chromium, with
// the same step-by-step orchestration as PassEngine.swift, so the automation
// can be checked (and fixed when the site changes) without a phone.
//
//   node run.mjs read                    # active pass and saved plates
//   node run.mjs activate PLATE          # cancel any other pass, create PLATE's
//   node run.mjs add PLATE NAME          # save a new plate (does not create a pass)
//   node run.mjs remove PLATE            # delete a saved plate with its trash icon
//   --dry-run                            # fill the forms, stop before the last click
//
// Uses PASS10X_BUILDING (default "Landmark 33"), PASS10X_SUITE and
// PASS10X_PASSWORD, plus PASS10X_CHROMIUM / PASS10X_CHROMIUM_ARGS / HTTPS_PROXY
// like scripts/pass10x/guestpass.mjs.

import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const HOME = 'https://www.pass10x.com/';
const script = readFileSync(new URL('../Parking/pass10x.js', import.meta.url), 'utf8');

const env = {
  building: process.env.PASS10X_BUILDING || 'Landmark 33',
  suite: process.env.PASS10X_SUITE,
  password: process.env.PASS10X_PASSWORD,
};
if (!env.suite || !env.password) throw new Error('set PASS10X_SUITE and PASS10X_PASSWORD');

const opts = { args: (process.env.PASS10X_CHROMIUM_ARGS || '').split(' ').filter(Boolean) };
if (process.env.PASS10X_CHROMIUM) opts.executablePath = process.env.PASS10X_CHROMIUM;
if (process.env.HTTPS_PROXY) opts.proxy = { server: process.env.HTTPS_PROXY };
const browser = await chromium.launch(opts);
// A phone-sized page, as in the app.
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true });
await page.addInitScript(script);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function step(name, args = {}) {
  if (process.env.TRACE) console.error('step', name);
  return page.evaluate(([n, a]) => window.P10[n](a), [name, args]);
}
const where = () => page.evaluate(() => window.P10?.where() ?? {});

async function waitFor(pred, what, timeout = 20000) {
  const end = Date.now() + timeout;
  for (;;) {
    let w = {};
    try { w = await where(); } catch {}
    if (pred(w)) return w;
    if (w.loginError) throw new Error(w.loginError);
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(300);
  }
}

async function load(url) {
  await page.goto(url, { waitUntil: 'load' });
}

async function ensureDashboard() {
  await load(new URL('/dashboard', HOME).href);
  const w = await waitFor((w) => w.dashboard || w.home || w.signin, 'dashboard or home', 10000).catch(() => ({}));
  if (w.dashboard) return;
  console.error('logging in');
  await load(HOME);
  await waitFor((w) => w.home, 'home page');
  await step('chooseBuilding', { building: env.building });
  await waitFor((w) => w.buildingChosen, 'building chosen');
  await step('chooseResident', { suite: env.suite });
  await waitFor((w) => w.signin, 'sign in page');
  await step('submitLogin', { password: env.password });
  await waitFor((w) => w.dashboard, 'dashboard after login');
}

async function openManage() {
  await ensureDashboard();
  await step('openManage');
  await waitFor((w) => w.manage, 'Manage Parking');
}

async function read() {
  await openManage();
  return step('readParking');
}

async function activate(plate, dryRun) {
  let state = await read();
  if (dryRun) {
    await step('openCreate', { plate });
    await waitFor((w) => w.passForm, 'pass form');
    return step('submitPass', { plate, dryRun });
  }
  for (const p of state.active.filter((p) => norm(p.plate) !== norm(plate))) {
    console.error(`cancelling ${p.plate} (${p.name})`);
    await step('cancelPass', { plate: p.plate });
  }
  if (state.active.some((p) => norm(p.plate) === norm(plate))) return { already: true };
  await step('openCreate', { plate });
  await waitFor((w) => w.passForm, 'pass form');
  await step('submitPass', { plate });
  const w = await waitFor((w) => w.passCreated || w.messages.length, 'pass result');
  if (!w.passCreated) throw new Error(w.messages.join(' '));
  state = await read();
  return state.active;
}

async function add(plate, name, dryRun) {
  await openManage();
  const filled = await step('saveVisitor', { plate, name, dryRun });
  if (dryRun) return filled;
  return (await step('readParking')).saved;
}

async function remove(plate, dryRun) {
  await openManage();
  const found = await step('removeVisitor', { plate, dryRun });
  if (dryRun) return found;
  return (await step('readParking')).saved;
}

const norm = (s) => (s || '').replace(/[\s-]/g, '').toUpperCase();
const dryRun = process.argv.includes('--dry-run');
const [cmd, ...rest] = process.argv.slice(2).filter((a) => a !== '--dry-run');
try {
  let out;
  if (cmd === 'read') out = await read();
  else if (cmd === 'activate') out = await activate(rest[0], dryRun);
  else if (cmd === 'add') out = await add(rest[0], rest.slice(1).join(' '), dryRun);
  else if (cmd === 'remove') out = await remove(rest[0], dryRun);
  else throw new Error('usage: run.mjs read | activate PLATE | add PLATE NAME | remove PLATE');
  console.log(JSON.stringify(out, null, 2));
} catch (e) {
  console.error(e.message);
  await page.screenshot({ path: 'run-error.png', fullPage: true }).catch(() => {});
  process.exitCode = 1;
} finally {
  await browser.close();
}
