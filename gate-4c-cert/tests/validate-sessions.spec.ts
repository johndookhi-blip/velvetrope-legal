import { test, expect, Request } from '@playwright/test';
import {
  STAGING_URL, STAGING_SUPABASE_HOST, STAGING_APP_ID, MOCK_VENUE_ID,
  PROD_APP_ID, PROD_SUPABASE_HOST, ACTORS,
} from '../playwright.config';

// Gate 4C · SESSION VALIDATION (item 5).
// Run this FIRST, per role project. It proves the loaded storageState session is:
//   authenticated · staging · correct role · NOT production.
// If any assertion fails, that role's session is not usable and Gate 4C must not start.
//
//   Run all roles:   npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions
//   Run one role:    npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions --project=owner

const ROLE = process.env.PW_PROJECT || '';   // Playwright sets project via --project; also readable in-test below.

test.describe('session validation', () => {
  // Hard production-isolation guard: fail the run if ANY request touches a production host/app id.
  test.beforeEach(async ({ page }) => {
    page.on('request', (req: Request) => {
      const u = req.url();
      if (u.includes(PROD_SUPABASE_HOST) || u.includes(PROD_APP_ID)) {
        throw new Error(`PRODUCTION ISOLATION VIOLATION: request touched production -> ${u}`);
      }
    });
  });

  test('authenticated · staging · correct role · not production', async ({ page }, testInfo) => {
    const role = testInfo.project.name as keyof typeof ACTORS;
    const expectedEmail = ACTORS[role].email;

    // Capture network to assert staging endpoints and absence of production endpoints.
    const hosts = new Set<string>();
    page.on('request', (r) => { try { hosts.add(new URL(r.url()).host); } catch {} });

    // (1) STAGING host — navigate to the app root.
    await page.goto(STAGING_URL, { waitUntil: 'networkidle' });
    expect(new URL(page.url()).host).toBe('preview--velvet-rope-staging.base44.app');

    // (2) AUTHENTICATED — not bounced to a login/sign-in screen.
    await expect(page).not.toHaveURL(/login|signin|sign-in|auth\/?$/i);
    const authToken = await page.evaluate(() => {
      const hit = Object.keys(localStorage).find(k => /base44|supabase|auth|token|session/i.test(k));
      return hit ? localStorage.getItem(hit) : null;
    });
    expect(authToken, 'expected an auth/session token in localStorage').toBeTruthy();

    // (3) CORRECT ROLE + IDENTITY — the app resolves this session to the expected staff email,
    //     role, and the Neon Room venue. Probe the app's own client (base44.auth.me()) if exposed,
    //     else assert the UI surfaces the expected identity. Adjust selector to the app if needed.
    const me = await page.evaluate(async () => {
      // @ts-ignore - the app exposes a base44 client at runtime
      if (window.base44?.auth?.me) { try { return await window.base44.auth.me(); } catch { return null; } }
      return null;
    });
    if (me) {
      expect(String(me.email).toLowerCase()).toBe(expectedEmail.toLowerCase());
    } else {
      // Fallback: the account email must be visible somewhere in the authenticated shell.
      await expect(page.getByText(expectedEmail, { exact: false })).toBeVisible({ timeout: 15_000 });
    }

    // (4) STAGING DATA PLANE — the app talked to the staging Supabase project, never production.
    //     (Give the app a beat to issue its data calls.)
    await page.waitForTimeout(2_000);
    expect([...hosts].some(h => h === STAGING_SUPABASE_HOST || h.endsWith('base44.app')),
      `expected staging endpoints; saw: ${[...hosts].join(', ')}`).toBeTruthy();
    expect([...hosts].some(h => h === PROD_SUPABASE_HOST),
      'production Supabase host must NOT appear').toBeFalsy();

    // (5) NEON ROOM scope — the selected/active venue is the mock venue.
    const venueOk = await page.evaluate((vid) => {
      const inLS = Object.keys(localStorage).some(k => (localStorage.getItem(k) || '').includes(vid));
      return inLS || document.body.innerText.includes('Neon Room');
    }, MOCK_VENUE_ID);
    expect(venueOk, 'expected Neon Room / mock venue id in session context').toBeTruthy();

    await testInfo.attach(`${role}-authenticated`, {
      body: await page.screenshot({ fullPage: true }), contentType: 'image/png',
    });
  });
});
