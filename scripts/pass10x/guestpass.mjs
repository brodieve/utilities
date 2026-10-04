#!/usr/bin/env node
//
// guestpass.mjs
//
// Create, list and cancel visitor parking passes on pass10x.com by driving
// the resident web app in a headless Chromium.
//
//   guestpass create ABC123 "Pat Guest"     # save ABC123 if new, then a 24 hour pass
//   guestpass create ABC123 --replace       # cancel the suite's active pass first
//   guestpass create ABC123 --dry-run       # fill the forms, do not save or submit
//   guestpass list                          # active visitor passes
//   guestpass plates                        # saved visitor plates
//   guestpass cancel ABC123                 # cancel the active pass for ABC123
//
// How the pieces fit:
//
//   - Pass10x has no public API worth relying on, so this does what a person
//     does: pick the building on the home page, choose RESIDENT, log in, then
//     use the dashboard. Going straight to /signin skips the RESIDENT choice
//     and the login is refused, so always start from the home page.
//   - Passes are made from saved plates, as in the app: Manage Parking lists
//     "Previously Parked Plates", each with a Create button that opens the
//     pass form filled in with that plate and its saved name. A plate that is
//     not saved yet is added first with "Setup a Visitor Pass".
//   - A suite may hold only one 24 hour visitor pass at a time. create
//     refuses when another plate's pass is active unless --replace is given.
//   - Saved plates are only ever added, never edited or deleted. Their rows
//     carry a trash icon next to Create; the only thing clicked in a row is
//     the button labelled Create. Cancelling only touches the "Active Visitor
//     Parking Passes" table (the one with an "Extend Time" column).
//
// Credentials come from the environment, or the macOS Keychain:
//
//   PASS10X_SUITE      suite / user id (required)
//   PASS10X_PASSWORD   password; if unset, read from the Keychain item
//                      service "pass10x", account $PASS10X_SUITE
//   PASS10X_BUILDING   building search text (default "Landmark 33")
//   PASS10X_CHROMIUM   Chromium executable, if Playwright's own is not installed
//   PASS10X_CHROMIUM_ARGS  extra Chromium flags, space separated
//   HTTPS_PROXY        used as the browser's proxy when set

import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';

const HOME = 'https://www.pass10x.com/';
const PASS_TYPE = '24 Hour Visitor Pass';

const usage = `usage:
  guestpass create PLATE [NAME] [--phone NUMBER] [--replace] [--dry-run]
  guestpass list
  guestpass plates
  guestpass cancel PLATE

  NAME is saved with a new plate; for a saved plate it overrides the saved
  name on this pass only.

  --replace    cancel the suite's active visitor pass first (one per suite)
  --dry-run    fill in the forms and stop before saving or submitting
  --phone N    10 digit cell number for the expiry text
  --headed     show the browser
  -h, --help   show help`;

function parseArgs(argv) {
  const opts = { positional: [], replace: false, dryRun: false, headed: false, phone: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { console.log(usage); process.exit(0); }
    else if (a === '--replace') opts.replace = true;
    else if (a === '--dry-run' || a === '-n') opts.dryRun = true;
    else if (a === '--headed') opts.headed = true;
    else if (a === '--phone') opts.phone = argv[++i] ?? '';
    else if (a.startsWith('-')) die(`unknown option: ${a}\n\n${usage}`);
    else opts.positional.push(a);
  }
  return opts;
}

function die(msg) {
  console.error(msg);
  process.exit(1);
}

function credentials() {
  const suite = process.env.PASS10X_SUITE;
  if (!suite) die('PASS10X_SUITE is not set');
  let password = process.env.PASS10X_PASSWORD;
  if (!password && process.platform === 'darwin') {
    try {
      password = execFileSync('security', ['find-generic-password', '-s', 'pass10x', '-a', suite, '-w'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch {}
  }
  if (!password) die('no password: set PASS10X_PASSWORD or add it to the Keychain with\n' +
    `  security add-generic-password -s pass10x -a ${suite} -w`);
  return { suite, password, building: process.env.PASS10X_BUILDING || 'Landmark 33' };
}

const normPlate = (p) => p.replace(/[\s-]/g, '').toUpperCase();

async function launch(headed) {
  const opts = { headless: !headed, args: (process.env.PASS10X_CHROMIUM_ARGS || '').split(' ').filter(Boolean) };
  if (process.env.PASS10X_CHROMIUM) opts.executablePath = process.env.PASS10X_CHROMIUM;
  if (process.env.HTTPS_PROXY) opts.proxy = { server: process.env.HTTPS_PROXY };
  const browser = await chromium.launch(opts);
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
  page.setDefaultTimeout(20000);
  return { browser, page };
}

async function login(page, { suite, password, building }) {
  await page.goto(HOME, { waitUntil: 'networkidle' });
  await page.getByPlaceholder('Search...').fill(building);
  const option = page.locator('li').filter({ hasText: building }).first();
  await option.waitFor();
  await option.click();
  await page.locator('input[name=suite]').fill(suite);
  await page.getByRole('button', { name: 'RESIDENT' }).click();
  await page.locator('input[type=password]').fill(password);
  await page.getByRole('button', { name: 'LOGIN' }).click();
  const outcome = await Promise.race([
    page.waitForURL('**/dashboard').then(() => 'ok'),
    page.getByText('Error signing').waitFor().then(() => 'refused'),
  ]);
  if (outcome !== 'ok') die(`login refused for suite ${suite} at ${building}`);
}

async function openDashboard(page) {
  if (!page.url().endsWith('/dashboard')) {
    await page.goto(new URL('/dashboard', HOME).href, { waitUntil: 'networkidle' });
  }
  await page.getByRole('button', { name: 'MANAGE PARKING' }).waitFor();
}

// The active visitor pass table, and nothing else on the page.
function activeTable(page) {
  return page.locator('table').filter({ has: page.locator('th', { hasText: 'Extend Time' }) });
}

async function openManage(page) {
  await openDashboard(page);
  await page.getByRole('button', { name: 'MANAGE PARKING' }).click();
  await page.getByText('Active Visitor Parking Passes').waitFor();
  await activeTable(page).waitFor();
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1500);
}

async function activePasses(page) {
  await openManage(page);
  return activeTable(page).locator('tbody tr').evaluateAll((rows) => rows.map((r) => {
    const cells = [...r.querySelectorAll('th, td')].map((c) => c.innerText.trim());
    // [delete button, name, plate, cell, start, end, extend button]
    return { name: cells[1], plate: cells[2], phone: cells[3], start: cells[4], end: cells[5] };
  }));
}

async function cancelPass(page, plate) {
  await openManage(page);
  // The table renders empty and fills in once the passes load.
  const row = activeTable(page).locator('tbody tr').filter({ hasText: plate });
  await row.first().waitFor({ timeout: 10000 }).catch(() => {});
  if (await row.count() !== 1) die(`no single active pass for ${plate}`);
  const rowPlate = await row.locator('td').nth(1).innerText();
  if (normPlate(rowPlate) !== plate) die(`active pass row shows ${rowPlate}, not ${plate}`);
  page.once('dialog', (d) => d.accept());
  await row.getByRole('button', { name: 'delete' }).click();
  // Some builds confirm in an in-page dialog rather than window.confirm.
  const confirm = page.getByRole('dialog').getByRole('button', { name: /^(yes|ok|confirm|delete|cancel pass)$/i });
  if (await confirm.isVisible({ timeout: 2000 }).catch(() => false)) await confirm.click();
  await row.waitFor({ state: 'detached', timeout: 15000 }).catch(() => {});
  const still = (await activePasses(page)).some((p) => normPlate(p.plate) === plate);
  if (still) die(`pass for ${plate} is still active after cancelling`);
}

// The saved plates are not a table: each row is a div holding the plate in a
// <p>, a "Create" button, and unlabelled trash and edit icons.
function savedRow(page, plate) {
  return page.locator(`xpath=//p[normalize-space()='${plate}']/ancestor::div[.//button[normalize-space()='Create']][1]`);
}

async function savedPlates(page) {
  await openManage(page);
  return page.locator('xpath=//button[normalize-space()="Create"]').evaluateAll((buttons) => buttons.map((b) => {
    let row = b.parentElement;
    while (row && row.querySelectorAll('p').length < 2) row = row.parentElement;
    return row ? row.querySelector('p').innerText.trim() : '';
  }).filter(Boolean));
}

// "Setup a Visitor Pass" on Manage Parking: Plate, Name, Cell #, Save Visitor.
function setupInput(page, label) {
  return page.locator(`xpath=//label[normalize-space()='${label}']/following-sibling::div//input`);
}

async function saveVisitor(page, { plate, name, phone, dryRun }) {
  await openManage(page);
  await setupInput(page, 'Plate').fill(plate);
  if (name) await setupInput(page, 'Name').fill(name);
  if (phone) await setupInput(page, 'Cell #').fill(phone);
  if (dryRun) {
    await page.screenshot({ path: 'guestpass-dry-run.png', fullPage: true });
    console.log(`dry run: ${plate} is not saved; filled Setup a Visitor Pass, not saved (guestpass-dry-run.png)`);
    return false;
  }
  let alertText = '';
  page.once('dialog', async (d) => { alertText = d.message(); await d.accept(); });
  await page.locator('xpath=//button[normalize-space()="Save Visitor"]').click();
  await page.waitForLoadState('networkidle');
  if (!(await savedPlates(page)).includes(plate)) {
    die(`could not save ${plate}: ${alertText || 'no message from the site'}`);
  }
  return true;
}

async function createFromSaved(page, { plate, name, phone, dryRun }) {
  await openManage(page);
  const row = savedRow(page, plate);
  if (await row.count() !== 1) die(`no single saved plate ${plate}`);
  const create = row.locator('xpath=.//button[normalize-space()="Create"]');
  if (await create.count() !== 1) die(`saved plate ${plate} has no single Create button`);
  await create.click();

  await page.waitForURL('**/sendpasstext');
  const form = page.locator('form');
  const submit = form.getByRole('button', { name: 'Create Visitor Parking Pass' });
  await submit.waitFor();
  const plateInput = form.getByRole('combobox').locator('input');
  await page.waitForFunction((el) => el.value !== '', await plateInput.elementHandle());
  const shownPlate = await plateInput.inputValue();
  if (normPlate(shownPlate) !== plate) die(`pass form opened with ${shownPlate}, not ${plate}`);
  await form.locator('select').selectOption(PASS_TYPE);
  const nameInput = form.locator('input[name=name]');
  if (name && (await nameInput.inputValue()) !== name) await nameInput.fill(name);
  if (phone) await form.locator('input[name=phoneno]').fill(phone);
  const passName = await nameInput.inputValue();

  if (dryRun) {
    await page.screenshot({ path: 'guestpass-dry-run.png', fullPage: true });
    console.log('dry run: pass form filled from the saved plate, not submitted (guestpass-dry-run.png)');
    return;
  }

  let alertText = '';
  page.once('dialog', async (d) => { alertText = d.message(); await d.accept(); });
  await submit.click();
  const ok = await page.getByText('Visitor Pass Created Successfully').waitFor({ timeout: 20000 })
    .then(() => true, () => false);
  if (!ok) die(`pass for ${plate} was not created: ${alertText || 'no message from the site'}`);

  const pass = (await activePasses(page)).find((p) => normPlate(p.plate) === plate);
  return pass || { plate, name: passName, start: '?', end: '?' };
}

async function createPass(page, opts) {
  if (!(await savedPlates(page)).includes(opts.plate)) {
    if (!(await saveVisitor(page, opts))) return;
    console.log(`saved ${opts.plate}${opts.name ? ` (${opts.name})` : ''}`);
  }
  return createFromSaved(page, opts);
}

function show(pass) {
  return `${pass.plate}  ${pass.name || '-'}  ${pass.start} -> ${pass.end}`;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const [command, ...rest] = opts.positional;
  if (!command) die(usage);

  const { browser, page } = await launch(opts.headed);
  try {
    await login(page, credentials());

    if (command === 'list') {
      const passes = await activePasses(page);
      console.log(passes.length ? passes.map(show).join('\n') : 'no active visitor passes');
    } else if (command === 'plates') {
      const plates = await savedPlates(page);
      console.log(plates.length ? plates.join('\n') : 'no saved plates');
    } else if (command === 'cancel') {
      if (!rest[0]) die(usage);
      const plate = normPlate(rest[0]);
      await cancelPass(page, plate);
      console.log(`cancelled pass for ${plate}`);
    } else if (command === 'create') {
      if (!rest[0]) die(usage);
      const plate = normPlate(rest[0]);
      const name = rest.slice(1).join(' ');
      if (opts.phone && !/^\d{10}$/.test(opts.phone)) die('--phone must be 10 digits');

      const active = await activePasses(page);
      const same = active.find((p) => normPlate(p.plate) === plate);
      if (same) {
        console.log(`already active: ${show(same)}`);
        return;
      }
      const others = active.filter((p) => normPlate(p.plate) !== plate);
      if (others.length && !opts.replace && !opts.dryRun) {
        die(`the suite already has an active pass (one allowed at a time):\n  ${others.map(show).join('\n  ')}\n` +
          're-run with --replace to cancel it first');
      }
      if (opts.replace && !opts.dryRun) {
        for (const p of others) {
          await cancelPass(page, normPlate(p.plate));
          console.log(`cancelled pass for ${p.plate} (${p.name || 'no name'})`);
        }
      }
      const pass = await createPass(page, { plate, name, phone: opts.phone, dryRun: opts.dryRun });
      if (pass) console.log(`created: ${show(pass)}`);
    } else {
      die(usage);
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => die(e.message));
