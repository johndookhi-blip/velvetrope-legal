# Capturing the six authenticated staging sessions (one-time, human-run)

The certification reuses **human-captured** sessions — it never logs in programmatically and never
handles passwords. A human with access to the six mock-night mailboxes/logins runs this once per role.

## Prereqs
- Node + `@playwright/test` installed in the app repo (or anywhere you run this harness).
- Chromium (already present in this environment at `/opt/pw-browsers/chromium`).
- Login ability for each mock-night account (password or magic-link email access).

## Capture (per role) — interactive login, then save storageState
```bash
# Example for OWNER; repeat for manager, host, door, server, promoter.
npx playwright open --save-storage=gate-4c-cert/.auth/owner.json \
  https://preview--velvet-rope-staging.base44.app
```
In the opened Chromium window:
1. Log in as the role's account (see the email map in README §1 / playwright.config.ts `ACTORS`).
2. Select the **__MOCK_NIGHT__ Neon Room** venue if prompted.
3. Confirm you see the authenticated app shell for that role.
4. Close the window — Playwright writes the authenticated session to the `--save-storage` path.

Resulting files (item 3), all git-ignored (they hold live tokens):
```
gate-4c-cert/.auth/owner.json
gate-4c-cert/.auth/manager.json
gate-4c-cert/.auth/host.json
gate-4c-cert/.auth/door.json
gate-4c-cert/.auth/server.json
gate-4c-cert/.auth/promoter.json
```

## Security
- **Never commit** `.auth/*.json` — they contain live auth tokens. `.auth/.gitignore` already blocks them.
- Sessions expire; if validation fails on auth, re-capture that role.
- Capture against staging ONLY (`preview--velvet-rope-staging.base44.app`). Never production.
