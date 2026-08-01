import { test, expect, Request } from '@playwright/test';
import { STAGING_URL, PROD_APP_ID, PROD_SUPABASE_HOST } from '../playwright.config';

// Gate 4C · REGRESSION MATRIX (runs ONLY after validate-sessions passes for the required roles).
// This is the executable skeleton for the certification the user requires. Each test maps to a
// success-criteria row. Selectors are intentionally left as TODOs to be bound to the live app during
// the actual run (kept test.fixme so a premature run cannot report a false pass).
//
//   npx playwright test --config=gate-4c-cert/playwright.config.ts gate4c --project=owner   (etc.)

// Global production-isolation guard for every certification test.
test.beforeEach(async ({ page }) => {
  page.on('request', (req: Request) => {
    const u = req.url();
    if (u.includes(PROD_SUPABASE_HOST) || u.includes(PROD_APP_ID)) {
      throw new Error(`PRODUCTION ISOLATION VIOLATION -> ${u}`);
    }
  });
  await page.goto(STAGING_URL, { waitUntil: 'networkidle' });
});

// role coverage: owner/manager = create+confirm+financial; host = walk-in+seating+floor;
// door = check-in; server = POS order lifecycle + total_spend; promoter = attribution.

test.fixme('owner/manager: reservation creation succeeds (no reservation_time/status errors)', async () => {});
test.fixme('owner/manager: reservation confirmation persists reservation_status=confirmed', async () => {});
test.fixme('host: walk-in creation', async () => {});
test.fixme('door: door check-in -> arrived', async () => {});
test.fixme('host: table assignment', async () => {});
test.fixme('host: floor execution (seat / occupied)', async () => {});
test.fixme('server: POS order creation + add items + financial recompute', async () => {});
test.fixme('server: close order -> total_spend recalculates automatically', async () => {});
test.fixme('owner/manager: settlement calculations', async () => {});
test.fixme('owner/manager: financial reconciliation (total_spend vs closed-order aggregate)', async () => {});
test.fixme('regression: existing dashboards/views load without console or network errors', async () => {});
