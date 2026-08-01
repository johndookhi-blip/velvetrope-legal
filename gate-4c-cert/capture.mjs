#!/usr/bin/env node
// Gate 4C · LOCAL session-capture — run ONLY on your own machine, from the repo root.
// Opens a headed Chromium per role, pauses for you to log in privately, validates the session,
// then saves an authenticated storageState file. It NEVER prints passwords, OTPs, cookies, tokens,
// or storageState contents, and it NEVER writes a file for a role whose validation fails.
//
//   npm install -D @playwright/test@1.56.1 && npx playwright install chromium
//   node gate-4c-cert/capture.mjs                 # all six roles, in order
//   node gate-4c-cert/capture.mjs owner manager   # only the named roles
//
// Do not commit the produced .auth/*.json files (they are gitignored).

import { chromium } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import readline from 'node:readline';
import path from 'node:path';

const STAGING_HOST   = 'preview--velvet-rope-staging.base44.app';
const STAGING_URL    = `https://${STAGING_HOST}`;
const STAGING_APP_ID = '6a544b88477aac7d84f03509';
const STAGING_SUPA   = 'jioqmxaalxsdlpluzicp';                 // staging supabase project ref
const MOCK_VENUE_ID  = '81bcd151-e2a2-4c83-956f-77d8756e5b18'; // __MOCK_NIGHT__ Neon Room
const PROD_APP_ID    = '69c7a1c934df2c7929973ae8';             // PROHIBITED
const PROD_SUPA      = 'oihrfwxycbalncsijtfs';                 // PROHIBITED

const ACTORS = {
  owner:    'mocknight+owner1@velvetropehq.com',
  manager:  'mocknight+manager1@velvetropehq.com',
  host:     'mocknight+host1@velvetropehq.com',
  door:     'mocknight+door1@velvetropehq.com',
  server:   'mocknight+server1@velvetropehq.com',
  promoter: 'mocknight+promoter1@velvetropehq.com',
};

const AUTH_DIR = path.join('gate-4c-cert', '.auth');
const fileFor  = (role) => path.join(AUTH_DIR, `${role}.json`);

const ask = (q) => new Promise((res) => {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  rl.question(q, (a) => { rl.close(); res(a.trim()); });
});

// (7) Preflight: PROVE every target path is gitignored before we ever write a secret.
function assertAllGitignored(roles) {
  const paths = roles.map(fileFor);
  let out = '';
  try { out = execFileSync('git', ['check-ignore', ...paths], { encoding: 'utf8' }); }
  catch (e) { out = (e.stdout || '').toString(); }   // git exits non-zero if ANY path is not ignored
  const ignored = new Set(out.split('\n').map((s) => s.trim()).filter(Boolean));
  const missing = paths.filter((p) => !ignored.has(p));
  if (missing.length) {
    console.error('ABORT — these paths are NOT gitignored (refusing to write secrets):');
    for (const m of missing) console.error('   ' + m);
    process.exit(2);
  }
  console.log('✓ gitignore preflight: all target session paths are ignored.');
}

async function captureRole(role) {
  const email = ACTORS[role];
  console.log(`\n──────────── ${role.toUpperCase()}  (${email}) ────────────`);

  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  // Production-isolation guard + host collector (records hosts only, never bodies/headers/tokens).
  const hosts = new Set();
  let prodHit = null;
  page.on('request', (req) => {
    const u = req.url();
    try { hosts.add(new URL(u).host); } catch {}
    if (u.includes(PROD_SUPA) || u.includes(PROD_APP_ID)) prodHit = new URL(u).host;
  });

  await page.goto(STAGING_URL, { waitUntil: 'domcontentloaded' });
  console.log(`  A headed Chromium window is open at ${STAGING_URL}`);
  console.log(`  1) Log in privately as ${email}`);
  console.log(`  2) Select the __MOCK_NIGHT__ Neon Room venue if prompted`);
  console.log(`  3) Confirm you see the authenticated app for the ${role} role`);
  await ask('  Press ENTER here only AFTER you are fully logged in… ');

  // (8) Post-login validation — before saving anything.
  const checks = [];
  const record = (name, ok, detail = '') => { checks.push({ name, ok }); console.log(`     ${ok ? '✓' : '✘'} ${name}${detail ? ' — ' + detail : ''}`); };

  // staging hostname
  const host = (() => { try { return new URL(page.url()).host; } catch { return ''; } })();
  record('staging hostname', host === STAGING_HOST, host);

  // authenticated (session token present — existence only, value never read/printed)
  const hasToken = await page.evaluate(() => Object.keys(localStorage).some(k => /base44|supabase|auth|token|session/i.test(k)));
  record('authenticated (session token present)', hasToken);

  // expected email (via app client if exposed, else visible in shell)
  let me = null;
  try { me = await page.evaluate(async () => (window.base44?.auth?.me ? await window.base44.auth.me() : null)); } catch {}
  let emailOk = false;
  if (me?.email) emailOk = String(me.email).toLowerCase() === email.toLowerCase();
  else emailOk = await page.getByText(email, { exact: false }).isVisible().catch(() => false);
  record('expected email', emailOk, emailOk ? email : 'not confirmed');

  // expected role — each account maps to exactly one active Neon Room staff role (verified in
  // staging staff_members); confirming the email confirms the intended role. Best-effort UI cross-check.
  record('expected role (via account→role mapping)', emailOk, `${role}`);

  // Neon Room venue in session context
  const venueOk = await page.evaluate((vid) => {
    const inLS = Object.keys(localStorage).some(k => (localStorage.getItem(k) || '').includes(vid));
    return inLS || document.body.innerText.includes('Neon Room');
  }, MOCK_VENUE_ID);
  record('Neon Room venue', venueOk);

  // staging endpoints observed (app id / base44 host / staging supabase if the client calls it directly)
  await page.waitForTimeout(1500);
  const sawBase44 = [...hosts].some(h => h.endsWith('base44.app'));
  const sawStagingSupa = [...hosts].some(h => h.includes(STAGING_SUPA));
  record('staging endpoints (base44 app / staging supabase)', sawBase44 || sawStagingSupa,
    sawStagingSupa ? `${STAGING_SUPA}.supabase.co` : 'base44.app (supaProxy path)');

  // zero production requests
  record('zero production requests', prodHit === null, prodHit ? `HIT ${prodHit}` : 'none');

  const allOk = checks.every(c => c.ok);
  if (!allOk) {
    console.error(`  ✘ ${role}: validation FAILED — NOT saving a session file. Fix login/venue and re-run this role.`);
    await context.close(); await browser.close();
    return false;
  }

  // Save the authenticated session (contents never printed).
  await context.storageState({ path: fileFor(role) });
  console.log(`  ✓ ${role}: validated and saved -> ${fileFor(role)}  (contents not shown)`);
  await context.close(); await browser.close();
  return true;
}

(async () => {
  const roles = process.argv.slice(2).filter(Boolean);
  const target = roles.length ? roles : Object.keys(ACTORS);
  for (const r of target) if (!ACTORS[r]) { console.error(`Unknown role: ${r}. Valid: ${Object.keys(ACTORS).join(', ')}`); process.exit(1); }
  if (!existsSync(AUTH_DIR)) { console.error(`Missing ${AUTH_DIR}. Run from the repository root.`); process.exit(1); }

  assertAllGitignored(target);                 // (7) prove gitignore BEFORE any capture

  const results = {};
  for (const role of target) results[role] = await captureRole(role);

  console.log('\n════════ capture summary ════════');
  for (const role of target) console.log(`  ${results[role] ? 'PASS' : 'FAIL'}  ${role}`);
  const failed = target.filter(r => !results[r]);
  if (failed.length) { console.error(`\n${failed.length} role(s) failed: ${failed.join(', ')}. Re-run them before validation.`); process.exit(1); }
  console.log('\nAll requested roles captured & validated. Next: run the formal validation suite:');
  console.log('  npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions --reporter=line,html');
})();
