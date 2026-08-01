import { defineConfig } from '@playwright/test';

// Gate 4C certification harness — STAGING ONLY.
// One Playwright "project" per actor role. Each project loads its own storageState
// (a captured authenticated session — see capture-sessions.md) via `storageState`.
// The certification NEVER logs in programmatically; it reuses human-captured sessions.

export const STAGING_URL   = 'https://preview--velvet-rope-staging.base44.app';
export const STAGING_APP_ID = '6a544b88477aac7d84f03509';
export const STAGING_SUPABASE_HOST = 'jioqmxaalxsdlpluzicp.supabase.co';
export const MOCK_VENUE_ID = '81bcd151-e2a2-4c83-956f-77d8756e5b18';

// Production identifiers that must NEVER appear in any request during certification.
export const PROD_APP_ID = '69c7a1c934df2c7929973ae8';
export const PROD_SUPABASE_HOST = 'oihrfwxycbalncsijtfs.supabase.co';

// role -> { storageState file, expected staff_members email }
export const ACTORS = {
  owner:    { file: './.auth/owner.json',    email: 'mocknight+owner1@velvetropehq.com'    },
  manager:  { file: './.auth/manager.json',  email: 'mocknight+manager1@velvetropehq.com'  },
  host:     { file: './.auth/host.json',     email: 'mocknight+host1@velvetropehq.com'     },
  door:     { file: './.auth/door.json',     email: 'mocknight+door1@velvetropehq.com'     },
  server:   { file: './.auth/server.json',   email: 'mocknight+server1@velvetropehq.com'   },
  promoter: { file: './.auth/promoter.json', email: 'mocknight+promoter1@velvetropehq.com' },
} as const;

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  reporter: [['list'], ['html', { outputFolder: 'report', open: 'never' }]],
  use: {
    baseURL: STAGING_URL,
    trace: 'on',
    screenshot: 'on',
    video: 'retain-on-failure',
  },
  projects: Object.entries(ACTORS).map(([role, cfg]) => ({
    name: role,                                   // run one role with:  --project=owner
    use: {
      storageState: cfg.file,                     // <-- item 4: how storageState is loaded
      baseURL: STAGING_URL,
    },
  })),
});
