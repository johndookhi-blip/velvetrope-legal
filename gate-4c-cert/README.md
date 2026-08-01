# Gate 4C — Authenticated Browser Certification Environment (prepared, blocked)

The Gate 4B review package is the **frozen implementation package**. Nothing is applied, published, or
deployed; no code or database was modified. This directory prepares **only** the certification harness so
Gate 4C can begin the moment six authenticated **staging** sessions exist. The blocker is authentication:
this session has the staff identities but no passwords/OTP/session for them.

---

## 1. Minimum actor roles required
Each role must be an **active** `staff_members` row for the Neon Room venue
(`81bcd151-e2a2-4c83-956f-77d8756e5b18`). Suggested accounts (verified active in staging):

| Role | Account (email) | Certifies |
|------|-----------------|-----------|
| **Owner** | `mocknight+owner1@velvetropehq.com` | reservation create + confirm; settlement; financial reconciliation; owner-only config |
| **Manager** | `mocknight+manager1@velvetropehq.com` | reservation create + confirm; POS adjustments; settlement |
| **Host** | `mocknight+host1@velvetropehq.com` | walk-in create; table assignment; floor execution (seating) |
| **Door** | `mocknight+door1@velvetropehq.com` | door check-in; arrived transition; scans |
| **Server** | `mocknight+server1@velvetropehq.com` | POS order create + items + payment + close; total_spend recalculation |
| **Promoter** | `mocknight+promoter1@velvetropehq.com` | promoter-linked reservation / attribution |

## 2. Exact staging URL to authenticate
```
https://preview--velvet-rope-staging.base44.app
```
(Base44 staging app `6a544b88477aac7d84f03509`; data plane `jioqmxaalxsdlpluzicp.supabase.co`.)

## 3. Exact Playwright storageState file names expected
```
gate-4c-cert/.auth/owner.json
gate-4c-cert/.auth/manager.json
gate-4c-cert/.auth/host.json
gate-4c-cert/.auth/door.json
gate-4c-cert/.auth/server.json
gate-4c-cert/.auth/promoter.json
```
Git-ignored (they hold live tokens) via `gate-4c-cert/.auth/.gitignore`. Capture them once with the
human-run steps in `capture-sessions.md`.

## 4. How those storageState files are loaded
Via `playwright.config.ts` — one **project per role**, each with `use.storageState` pointing at its file:
```ts
projects: Object.entries(ACTORS).map(([role, cfg]) => ({
  name: role,
  use: { storageState: cfg.file, baseURL: STAGING_URL },
}))
```
Run a role with `--project=<role>` (e.g. `--project=owner`); Playwright injects that session's cookies +
localStorage into the browser context, so every test in that project runs authenticated as that role.

## 5. Validation checklist — proving each session is authenticated · staging · correct role · not production
Implemented as runnable assertions in `tests/validate-sessions.spec.ts` (run before any certification):

- **Authenticated** — app root does not redirect to a login/sign-in route; an auth/session token is
  present in `localStorage`.
- **Staging** — page host is exactly `preview--velvet-rope-staging.base44.app`; observed data-plane
  requests hit `jioqmxaalxsdlpluzicp.supabase.co` / `*.base44.app`.
- **Correct role & identity** — `window.base44.auth.me()` (or the authenticated shell) resolves the
  expected `mocknight+<role>1@velvetropehq.com`; venue context is the Neon Room mock venue id.
- **Not production** — a request listener throws on ANY request touching production
  (`oihrfwxycbalncsijtfs.supabase.co` or app id `69c7a1c934df2c7929973ae8`); the staging Supabase host is
  present and the production host is absent.

Validate all six roles:
```
npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions
```
All six must pass before Gate 4C starts.

## 6. Final command that begins Gate 4C (once the six sessions exist and validate)
```
npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions \
  && npx playwright test --config=gate-4c-cert/playwright.config.ts gate4c
```
First gate on session validity, then run the regression matrix (`tests/gate4c.spec.ts`). The matrix tests
are `test.fixme` placeholders bound to the live app at run time, so a premature run cannot report a false
pass.

---

## Guardrails
No application code changed. No database changed. No publish. No deploy. Production never accessed.
storageState files are never committed.
