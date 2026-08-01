# Gate 4C — Local session recapture + validation (run on YOUR machine, repo root)

The six earlier storageState files are void. Recapture them locally with `capture.mjs`. Nothing here
touches staging/production; it only opens a browser for you to log in and saves local session files.
Session files stay on your machine (gitignored) and are never printed, committed, or transferred.

## 9a. Install dependencies (repo has no package.json)
```bash
node -v                                   # Node >= 18
npm init -y >/dev/null 2>&1 || true
npm install -D @playwright/test@1.56.1
npx playwright install chromium
```

## 9b. Capture each role (headed, one at a time, private login)
```bash
# all six in order:
node gate-4c-cert/capture.mjs

# or one/several at a time (re-run any that failed):
node gate-4c-cert/capture.mjs owner
node gate-4c-cert/capture.mjs manager host door server promoter
```
For each role the script: proves the target path is gitignored → opens headed Chromium at
`https://preview--velvet-rope-staging.base44.app` → waits for you to log in and pick **Neon Room** →
you press ENTER → it validates (email, role mapping, Neon Room venue, staging host, staging Supabase /
supaProxy path, zero production requests) → saves `gate-4c-cert/.auth/<role>.json` **only if all checks
pass**. It never prints passwords, OTPs, cookies, tokens, or file contents.

Produces (gitignored, keep local):
```
gate-4c-cert/.auth/owner.json  manager.json  host.json  door.json  server.json  promoter.json
```

## 9c. Validate all six sessions (formal gate)
```bash
# prove gitignore + presence (names only, never contents):
git check-ignore gate-4c-cert/.auth/{owner,manager,host,door,server,promoter}.json
ls -la gate-4c-cert/.auth/*.json

# run the validation suite (six role projects):
npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions --reporter=line,html

# if a role fails, isolate + trace it:
DEBUG=pw:api npx playwright test --config=gate-4c-cert/playwright.config.ts validate-sessions --project=owner --reporter=list --trace=on
npx playwright show-trace gate-4c-cert/test-results/*owner*/trace.zip
```

## What to send back
Only the console **pass/fail lines + summary** and any **redacted** assertion errors. Do NOT send the
`.auth/*.json` files, traces, screenshots, tokens, or passwords.

## Safety invariants enforced by the harness
- `.auth/*.json` gitignored (checked before any write) and never committed.
- No secret values printed (tokens/cookies/storageState contents never logged).
- Production isolation: any request to prod app `69c7a1c934df2c7929973ae8` or prod Supabase
  `oihrfwxycbalncsijtfs` fails the role (capture) / throws (validation).
- Staging only: `preview--velvet-rope-staging.base44.app`, app `6a544b88477aac7d84f03509`,
  Supabase `jioqmxaalxsdlpluzicp`, venue Neon Room `81bcd151-e2a2-4c83-956f-77d8756e5b18`.
