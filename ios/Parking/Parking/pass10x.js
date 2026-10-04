// pass10x.js
//
// Drives the Pass10x resident web app from inside a web view. The app injects
// this at document start on every page load and calls the window.P10
// functions one step at a time. A step that navigates returns as soon as it
// has clicked; the caller then polls P10.where() until the next page is up.
//
// Saved plates are only ever added. The only button pressed in a saved
// plate's row is the one labelled Create, never the trash or edit icons
// beside it. Cancelling only touches the active visitor pass table.
//
// tests/run.mjs runs this same file against the live site in Chromium.

(() => {
  if (window.P10) return;

  // Pass10x reports errors with alert(), and may confirm with confirm().
  // Record them instead of blocking, and say yes to confirmations.
  const messages = [];
  window.alert = (m) => { messages.push(String(m)); };
  window.confirm = (m) => { messages.push(String(m)); return true; };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const norm = (s) => (s || '').replace(/[\s-]/g, '').toUpperCase();
  const text = (el) => (el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : '');
  const bodyText = () => (document.body ? document.body.innerText : '');

  async function until(fn, what, timeout = 15000) {
    const end = Date.now() + timeout;
    for (;;) {
      let v;
      try { v = fn(); } catch {}
      if (v) return v;
      if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
      await sleep(200);
    }
  }

  // Buttons by their own text, ignoring CSS uppercasing.
  const buttons = (label) => [...document.querySelectorAll('button')]
    .filter((b) => text(b).toLowerCase() === label.toLowerCase());
  const button = (label) => buttons(label)[0];

  // Steps that navigate click just after returning, so a full page load
  // cannot cut off the call that is waiting for the step to finish.
  const clickSoon = (el) => setTimeout(() => el.click(), 50);

  // React tracks input values itself; set through the native setter and
  // fire the events it listens for.
  function setValue(el, value) {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function inputByLabel(label) {
    const l = [...document.querySelectorAll('label')].find((x) => text(x) === label);
    return l && l.parentElement.querySelector('input');
  }

  // --- where are we --------------------------------------------------------

  function where() {
    const body = bodyText();
    let loginError = '';
    if (/Error signing/.test(body)) loginError = 'Login refused: check the building, suite and password.';
    else if (/user\/suite has been reset/.test(body)) loginError = 'Pass10x says this suite has been reset.';
    else if (/user\/suite is in pending state/.test(body)) loginError = 'Pass10x says this suite is pending.';
    return {
      path: location.pathname,
      dashboard: !!button('Manage Parking'),
      home: !!document.querySelector('input[placeholder="Search..."]') && !document.querySelector('input[type=password]'),
      buildingChosen: !!button('Resident') && !!document.querySelector('input[name=suite]'),
      signin: !!document.querySelector('input[type=password]'),
      manage: !!activeTable(),
      passForm: !!button('Create Visitor Parking Pass'),
      passCreated: /Visitor Pass Created Successfully/.test(body),
      loginError,
      messages: messages.slice(),
    };
  }

  // --- login ---------------------------------------------------------------

  // Logging in takes three pages. Going straight to /signin skips the
  // RESIDENT choice and the login is refused, so this is the only way in.
  //
  // 1. Home page: pick the building. The page reloads with ?tlkey=...
  async function chooseBuilding({ building }) {
    const search = await until(() => document.querySelector('input[placeholder="Search..."]'), 'building search');
    search.focus();
    setValue(search, building);
    const option = await until(() => [...document.querySelectorAll('li')]
      .find((li) => text(li).toLowerCase().includes(building.toLowerCase())), `building "${building}" in search results`);
    clickSoon(option);
  }

  // 2. Home page with the building chosen: enter the suite, choose RESIDENT.
  async function chooseResident({ suite }) {
    const suiteInput = await until(() => document.querySelector('input[name=suite]'), 'suite field');
    setValue(suiteInput, suite);
    const resident = await until(() => button('Resident'), 'RESIDENT button');
    await sleep(200);
    clickSoon(resident);
  }

  // 3. Sign in page: enter the password and log in.
  async function submitLogin({ password }) {
    const pw = await until(() => document.querySelector('input[type=password]'), 'password field');
    setValue(pw, password);
    // Remember Me makes the site keep the password in local storage; the
    // app keeps it in the Keychain instead.
    const remember = document.querySelector('input[type=checkbox]');
    if (remember && remember.checked) remember.click();
    messages.length = 0;
    await sleep(200);
    clickSoon(await until(() => button('Login'), 'LOGIN button'));
  }

  // --- dashboard -----------------------------------------------------------

  async function openManage() {
    clickSoon(await until(() => button('Manage Parking'), 'MANAGE PARKING button'));
  }

  // --- manage parking ------------------------------------------------------

  function activeTable() {
    return [...document.querySelectorAll('table')]
      .find((t) => [...t.querySelectorAll('th')].some((th) => text(th) === 'Extend Time'));
  }

  function activeRows() {
    const t = activeTable();
    return t ? [...t.querySelectorAll('tbody tr')] : [];
  }

  function readActive() {
    return activeRows().map((r) => {
      // [delete button, name, plate, cell, start, end, extend button]
      const cells = [...r.querySelectorAll('th, td')].map(text);
      return { name: cells[1], plate: cells[2], phone: cells[3], start: cells[4], end: cells[5] };
    });
  }

  // Each saved plate is a block of divs: a chevron, the plate in a <p>, the
  // pass count, Create, trash and edit buttons, and a collapsed panel with
  // "Name:" and "Cell #".
  function savedRows() {
    return buttons('Create').map((create) => {
      let row = create.parentElement;
      while (row && row.querySelectorAll('p').length < 2) row = row.parentElement;
      if (!row) return null;
      const block = row.parentElement;
      return { plate: text(row.querySelector('p')), row, block, create };
    }).filter(Boolean);
  }

  function savedRow(plate) {
    const rows = savedRows().filter((r) => norm(r.plate) === norm(plate));
    if (rows.length !== 1) throw new Error(`expected one saved plate ${plate}, found ${rows.length}`);
    return rows[0];
  }

  async function waitForManage() {
    await until(() => activeTable(), 'Manage Parking');
    // The tables render first and fill in once the data arrives.
    await until(() => savedRows().length > 0, 'saved plates', 8000).catch(() => {});
    await sleep(800);
  }

  // Active passes and saved plates with their saved names. Names sit in a
  // collapsed panel, so each chevron is opened, read, and closed again.
  async function readParking() {
    await waitForManage();
    const saved = [];
    for (const r of savedRows()) {
      const chevron = r.row.querySelector('button');
      let name = '';
      let phone = '';
      if (chevron && chevron !== r.create) {
        chevron.click();
        const panel = await until(() => /Name:/.test(r.block.innerText) && r.block, `details for ${r.plate}`, 3000)
          .catch(() => null);
        if (panel) {
          name = (panel.innerText.match(/Name:[ \t]*(.*)/) || [])[1]?.trim() || '';
          phone = (panel.innerText.match(/Cell #[ \t]*:?[ \t]*(.*)/) || [])[1]?.trim() || '';
        }
        chevron.click();
      }
      saved.push({ plate: r.plate, name, phone });
    }
    return { active: readActive(), saved };
  }

  async function cancelPass({ plate }) {
    await waitForManage();
    const rows = activeRows().filter((r) => norm(text(r.querySelectorAll('td')[1])) === norm(plate));
    if (rows.length !== 1) throw new Error(`expected one active pass for ${plate}, found ${rows.length}`);
    const del = rows[0].querySelector('button[aria-label="delete"]');
    if (!del) throw new Error(`no cancel button on the pass for ${plate}`);
    messages.length = 0;
    del.click();
    // The site asks "Delete This Parking Pass?" in its own dialog. All of
    // the page's dialogs stay mounted and hidden, so find this one by its
    // message and wait for it to show.
    const dialog = await until(() => [...document.querySelectorAll('[role=dialog]')]
      .find((d) => /Delete This Parking Pass/i.test(text(d)) && getComputedStyle(d).visibility === 'visible'),
    `the confirmation to cancel the pass for ${plate}`, 5000);
    const confirm = [...dialog.querySelectorAll('button')].find((b) => /^confirm$/i.test(text(b)));
    if (!confirm) throw new Error(`no Confirm button when cancelling the pass for ${plate}`);
    confirm.click();
    const gone = () => !readActive().some((p) => norm(p.plate) === norm(plate));
    await until(() => gone() || /Failed to remove parking pass/i.test(bodyText()), `pass for ${plate} to be cancelled`);
    if (!gone()) throw new Error(`Pass10x could not cancel the pass for ${plate}. Try again.`);
    return { messages: messages.slice() };
  }

  // "Setup a Visitor Pass": adds a saved plate.
  async function saveVisitor({ plate, name, phone, dryRun }) {
    await waitForManage();
    const fields = { Plate: plate, Name: name || '', 'Cell #': phone || '' };
    for (const [label, value] of Object.entries(fields)) {
      const input = inputByLabel(label);
      if (!input) throw new Error(`no ${label} field in Setup a Visitor Pass`);
      if (value) setValue(input, value);
    }
    const save = await until(() => button('Save Visitor'), 'SAVE VISITOR button');
    if (dryRun) return { dryRun: true, filled: Object.keys(fields).map((l) => inputByLabel(l).value) };
    messages.length = 0;
    save.click();
    await until(() => savedRows().some((r) => norm(r.plate) === norm(plate)) || messages.length,
      `${plate} to appear in saved plates`);
    if (!savedRows().some((r) => norm(r.plate) === norm(plate))) {
      throw new Error(messages.join(' ') || `could not save ${plate}`);
    }
  }

  // Press Create on a saved plate; the site opens the pass form filled in.
  async function openCreate({ plate }) {
    await waitForManage();
    const r = savedRow(plate);
    clickSoon(r.create);
  }

  async function submitPass({ plate, name, phone, dryRun }) {
    const submit = await until(() => button('Create Visitor Parking Pass'), 'pass form');
    const form = submit.closest('form');
    const plateInput = await until(() => {
      const i = form.querySelector('[role=combobox] input') || form.querySelector('input[type=text]');
      return i && i.value && i;
    }, 'plate in pass form');
    if (norm(plateInput.value) !== norm(plate)) {
      throw new Error(`pass form opened with ${plateInput.value}, not ${plate}`);
    }
    const select = await until(() => form.querySelector('select'), 'pass type');
    if (select.value !== '24 Hour Visitor Pass') setValue(select, '24 Hour Visitor Pass');
    if (select.value !== '24 Hour Visitor Pass') throw new Error('no 24 Hour Visitor Pass option');
    const nameInput = form.querySelector('input[name=name]');
    if (name && nameInput && nameInput.value !== name) setValue(nameInput, name);
    if (phone) setValue(form.querySelector('input[name=phoneno]'), phone);
    if (dryRun) {
      return { dryRun: true, plate: plateInput.value, type: select.value, name: nameInput && nameInput.value };
    }
    messages.length = 0;
    await sleep(200);
    clickSoon(submit);
  }

  window.P10 = { where, chooseBuilding, chooseResident, submitLogin, openManage, readParking, cancelPass, saveVisitor, openCreate, submitPass };
})();
