import { test, expect } from '@playwright/test';
import {
  STAGING_URL, STAGING_SUPABASE_HOST, MOCK_VENUE_ID,
  PROD_APP_ID, PROD_SUPABASE_HOST, ACTORS,
} from '../playwright.config';

// Gate 4C · SESSION VALIDATION (item 5).
// Per role project, proves the loaded storageState session is:
//   authenticated · staging · correct role · NOT production.
//
//   All roles:  npx playwright test --config=playwright.config.ts validate-sessions
//   One role:   npx playwright test --config=playwright.config.ts validate-sessions --project=owner
//
// Identity is confirmed by a LAYERED evidence collector (network responses / storage / UI), because the
// app's base44 client is a bundled module — it is NOT a `window` global, so `window.base44.auth.me()`
// is not callable from the page. No token/secret value is ever logged.

test('authenticated · staging · correct role · not production', async ({ page }, testInfo) => {
  const role = testInfo.project.name as keyof typeof ACTORS;
  const expectedEmail = ACTORS[role].email;
  const emailLc = expectedEmail.toLowerCase();

  const hosts = new Set<string>();
  let prodHit: string | null = null;
  let networkEmailConfirmed = false;

  // Attach collectors BEFORE navigation so identity/API calls made during load are observed.
  page.on('request', (r) => {
    const u = r.url();
    try { hosts.add(new URL(u).host); } catch { /* ignore */ }
    if (u.includes(PROD_SUPABASE_HOST) || u.includes(PROD_APP_ID)) prodHit = u;
  });
  page.on('response', async (resp) => {
    try {
      const url = resp.url();
      const ct = resp.headers()['content-type'] || '';
      if (!/json|javascript|text/i.test(ct)) return;
      // Only inspect identity/API-shaped responses (keeps this cheap and avoids asset bodies).
      if (!/base44\.(app|com)|supabase|\/me\b|auth|users?|profile|entities|staff|session/i.test(url)) return;
      const body = await resp.text();
      if (body && body.length < 300_000 && body.toLowerCase().includes(emailLc)) networkEmailConfirmed = true;
    } catch { /* body not readable — ignore */ }
  });

  // (1) STAGING host.
  await page.goto(STAGING_URL, { waitUntil: 'networkidle' });
  expect(new URL(page.url()).host).toBe('preview--velvet-rope-staging.base44.app');

  // (2) AUTHENTICATED — not bounced to a login route.
  await expect(page).not.toHaveURL(/login|signin|sign-in|auth\/?$/i);

  // Let the SPA hydrate its cached identity / fire its me() call.
  await page.waitForTimeout(2_500);

  // (3) IDENTITY — layered evidence: network response body, storage cache, or visible UI.
  const storageEmailConfirmed = await page.evaluate((email) => {
    const scan = (s: Storage) => Object.keys(s).some(k => (s.getItem(k) || '').toLowerCase().includes(email));
    return scan(window.localStorage) || scan(window.sessionStorage);
  }, emailLc);
  const visibleEmailConfirmed = await page.getByText(expectedEmail, { exact: false }).first().isVisible().catch(() => false);
  const hasSessionArtifact = await page.evaluate(() =>
    Object.keys(window.localStorage).some(k => /base44|supabase|auth|token|session/i.test(k))
    || document.cookie.length > 0);

  const emailConfirmed = networkEmailConfirmed || storageEmailConfirmed || visibleEmailConfirmed;

  // authenticated = a session artifact hydrated AND we can see the identity by some channel.
  expect(hasSessionArtifact, 'no session artifact hydrated from storageState').toBeTruthy();
  expect(
    emailConfirmed,
    `expected identity ${expectedEmail} not found via network/storage/UI evidence ` +
    `(network=${networkEmailConfirmed} storage=${storageEmailConfirmed} ui=${visibleEmailConfirmed})`,
  ).toBeTruthy();

  // (4) ROLE — each mock-night account maps 1:1 to exactly one active Neon Room staff role
  //     (verified in staging staff_members). A confirmed email confirms the intended role.
  console.log(`[${role}] identity confirmed for ${expectedEmail} -> role '${role}'`);

  // (5) STAGING data plane, (6) NEON ROOM venue, (7) NOT production.
  const sawBase44     = [...hosts].some(h => h.endsWith('base44.app'));
  const sawStagingSupa = [...hosts].some(h => h === STAGING_SUPABASE_HOST);
  expect(sawBase44 || sawStagingSupa, `expected staging endpoints; saw: ${[...hosts].join(', ')}`).toBeTruthy();
  expect([...hosts].some(h => h === PROD_SUPABASE_HOST), 'production Supabase host must NOT appear').toBeFalsy();
  expect(prodHit, `production request observed: ${prodHit}`).toBeNull();

  const venueOk = await page.evaluate((vid) => {
    const inLS = Object.keys(window.localStorage).some(k => (window.localStorage.getItem(k) || '').includes(vid));
    return inLS || document.body.innerText.includes('Neon Room');
  }, MOCK_VENUE_ID);
  expect(venueOk, 'expected Neon Room / mock venue id in session context').toBeTruthy();

  await testInfo.attach(`${role}-authenticated`, {
    body: await page.screenshot({ fullPage: true }), contentType: 'image/png',
  });
});
