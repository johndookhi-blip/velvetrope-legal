# Velvet Rope — Gate 4B Final Launch Hardening · Review Package

**Date:** 2026-08-01 · **Scope:** staging investigation + prepared changes. **Nothing applied.**
Per owner direction: no migration applied, no Base44 deploy, no staging publish, no PR for app code,
mock-night deferred. This package targets the **Base44 staging app `6a544b88477aac7d84f03509`** and
**Supabase staging `jioqmxaalxsdlpluzicp`**; production was never touched.

---

## 1. Repository baseline
- Git checkout `/home/user/velvetrope-legal`, branch `claude/velvet-rope-gate-4a-hcp9wv`, clean tree.
  It holds **only the static legal site + review packages** — **not** the Velvet Rope application.
- **The real application repository is the Base44 staging app `6a544b88477aac7d84f03509`**
  (`src/`, `base44/functions/`, `supabase/migrations/`) + the staging Postgres schema. All Gate 4B
  findings and diffs refer to that app. This is why no application PR is created from this legal repo.
- Recent commits here: `09da7b4` (Gate 4A package), `731a558`, `e2e64c9`.

## 2. POST failure reproduction (Phase 2)
Reproduced at the DB layer (what supaProxy POSTs after authz), inside rolled-back transactions:

| Create path | Result | Evidence |
|---|---|---|
| `src/components/dashboard/NewReservationModal.jsx` | ❌ **FAILS** | `22007 invalid input syntax for type time: "2026-08-01T22:00"` |
| …same modal, valid time | ⚠️ wrong status | persists `reservation_status=pending` (intended `confirmed`) |
| `src/components/reservations/NewReservationModal.jsx` | ✅ inserts | canonical correct |
| Order create (open) | ✅ inserts | fine |

## 3. POST root cause (proven)
**Client payload defect — not supaProxy/authz/`venue_users`.**
1. **Type/column mismatch:** the dashboard modal writes the `datetime-local` value into
   `reservations.reservation_time` (`time without time zone`) → PostgREST 400/`22007`. The correct column
   is `arrival_time` (`timestamptz`).
2. **Status-only write:** it sends `status:'confirmed'` with no `reservation_status`; the BEFORE mirror
   `NEW.status := NEW.reservation_status` reverts it to the `pending` default.
Both are fixed in `base44_app_diffs.md` (Priority 1) and validated (test T22: fixed→`confirmed/confirmed`;
old payload→`22007`).

## 4. supaProxy changes — none needed (explanation)
`base44/functions/supaProxy/entry.ts` already enforces the required contract via `staff_members`:
server-side `auth.me()` email (never client-supplied), active-membership lookup, requested-venue must
match membership, venue hard-scoping (`venue_id=in.(memberVenues)`), create-must-name-member-venue,
deny-by-default write matrix, sensitive payout/POS columns owner/manager-only, fail-closed on
unresolved/absent membership and on any thrown error. The reproduced failure is upstream of supaProxy
(client payload). `venue_users` is the dormant future Supabase-Auth path (DB `auth_venue_role`) and is
**left unchanged** — no schema conversion. **No supaProxy edit is included.**

## 5. Reservation status audit (Phase 4)
Every reservation `status`/`reservation_status` write classified in `base44_app_diffs.md` (Priority 1+2)
and `../gate-4a-review/blocker2_code_changes.md`: **1 hard-failing status-only+type bug** (dashboard
modal), **1 status-only correctness bug** already folded into that fix, **11 dual-writes** to reduce to
canonical, plus documented already-canonical and out-of-scope writes. DB mirror kept.

## 6. Files changed
**No application files were changed/deployed.** Prepared diffs (for the app repo / Base44) live in
`base44_app_diffs.md`. Files **created in this legal repo** (review artifacts only): see §Files created.

## 7. total_spend contract (Phase 5)
> `reservations.total_spend` = Σ over **closed** orders of
> `subtotal + tax_amount + gratuity_amount + service_charge_amount − discount_amount − comp_amount`,
> each order floored at 0; **0** when none. **Excludes** `deposit_applied`, payments (`total_paid`), and
> post-close `financial_reversals` (refunds/chargebacks/voids — no separate tables exist). Open and
> deleted orders excluded. Grounded in: generated `orders.total_due` (which subtracts deposit_applied),
> the close-requires-settled and no-reopen guards, and the fact that `total_spend` has no DB writer today.

## 8. Migration SQL (Phase 6)
`migration_forward.sql` — index `idx_orders_reservation_id_status` (verified absent) + reusable
`recalculate_reservation_total_spend(uuid)` (idempotent, `FOR UPDATE`-locked, NULL-safe, zero-on-empty,
no swallowed exceptions) + `pos_writeback_to_reservation()` trigger fn (explicit `TG_OP` branches, OLD+NEW
recompute in ascending-UUID lock order, DELETE returns OLD, preserves `pos_total_amount` first-close
stamp) + trigger rewire to `AFTER INSERT OR UPDATE OR DELETE`. Optional idempotent backfill included
(commented). Suggested name `20260801_gate4b_reservation_total_spend`.

## 9. Rollback SQL
`migration_rollback.sql` — restores the exact original function body, `AFTER UPDATE`-only trigger, drops
`recalculate_reservation_total_spend`, drops the sprint index; optional total_spend restore from snapshot.

## 10. Reconciliation SQL
`snapshots_and_reconciliation.sql` — §1 pre-migration object+data snapshots and counts; §2 post-migration
independent-recompute check (expect 0 mismatches), change-surface vs snapshot, row-count parity; §3 cleanup.

## 11. Test results (Phase 7) — executed in rolled-back transactions, **20/20 groups PASS**
Certified against staging with the exact `migration_forward.sql` objects, then rolled back; live schema
verified unchanged.

| Group | Expected | Got | Pass |
|---|---|---|---|
| T1 no orders | 0 | 0 | ✅ |
| T2 open excluded | 0 | 0 | ✅ |
| T3 one closed | 133 | 133 | ✅ |
| T4 two closed (aggregate) | 154 | 154 | ✅ |
| T5 discount | 70 | 70 | ✅ |
| T6 comp | 0 | 0 | ✅ |
| T7/T8 gratuity+service | 130 | 130 | ✅ |
| T9-11 deposit+partial+full payment excluded | 100 | 100 | ✅ |
| T12 delete one closed order | 140→100 | 140→100 | ✅ |
| T13 delete last closed → 0 | 0 | 0 | ✅ |
| T14 order link removal (NULLing) | guard-blocked, total stable | blocked, 100→100 | ✅ |
| T15 A→B reassignment | guard-blocked | blocked | ✅ |
| T16 post-close reversal excluded | 100/100 | 100/100 | ✅ |
| T17 post-close manager edit recalcs | 200→215 | 200→215 | ✅ |
| T18 idempotent recalc ×3 | 321/321/321 | 321/321/321 | ✅ |
| T19 recalc(NULL) → NULL, no error | NULL | NULL | ✅ |
| T20 multi-order (2 closed+1 open) | 316 | 316 | ✅ |
| T21 open→close + pos stamp | ts120/pta120/closed | same | ✅ |
| T22 dashboard-fix persists confirmed | confirmed/confirmed | confirmed/confirmed | ✅ |
| T22b old payload still fails (regression guard) | fails 22007 | fails 22007 | ✅ |

**Concurrency (T-concurrent):** documented two-session procedure in `tests.sql`; expected final
`total_spend` = 250 via the `FOR UPDATE` serialization. **Requires two psql sessions — run at apply time.**

## 12. Deployment record
**None.** No migration applied, no Base44 function/bundle published. Previous/new bundle+function
versions: unchanged (no deploy performed).

## 13. Targeted regression results (Phase 9)
**Deferred** — requires the authenticated browser/supaProxy path (see §Credential prerequisites). Not
run. SQL/entity-level checks were **not** substituted for it.

## 14. Mock-night results (Phase 10)
**Deferred** — not run this sprint (owner direction). No mock-night certification is claimed.

## 15. Financial reconciliation
The reconciliation queries (§10) are prepared; a live reconciliation runs at apply time after the
optional backfill. Not executed as a certification here.

## 16. Production isolation proof
Every `execute_sql`/read targeted **only** `jioqmxaalxsdlpluzicp` (staging). Production Base44
`69c7a1c934df2c7929973ae8` and Supabase `oihrfwxycbalncsijtfs` were **never accessed**. Post-run staging
verification: `pos_writeback_to_reservation` unmodified (no `TG_OP`), `recalculate_reservation_total_spend`
absent, `trg_pos_writeback` still `AFTER UPDATE` only, sprint index absent, zero leftover test rows. All
test writes ran inside transactions that were rolled back.

## 17. Remaining risk register
| Risk | Severity | Note |
|---|---|---|
| Dashboard modal create is broken in production-intended path | High (blocker) | Fix prepared (Priority 1); not deployed |
| `total_spend` never populated by DB today | High | Automation prepared; not applied |
| Authenticated browser/supaProxy path uncertified | High (gating for launch) | No credentials; deferred |
| Dual-write `status` churn | Low | Harmless with mirror; cleanup prepared |
| Legacy dashboard modal duplicates canonical modal | Low | Recommend retiring the dashboard variant |
| `reservation_time` (time-of-day) column exists but is misused by one modal | Low | Fix rebinds to `arrival_time` |

## Launch recommendation
**NOT LAUNCH READY** — a core create path is broken in the production-intended flow (fix prepared but not
applied), `total_spend` automation is not yet live, and the authenticated browser/supaProxy certification
and mock night have not been run. All fixes are prepared and unit-certified in rolled-back transactions;
none are deployed.

---

## Files created (in this legal repo, branch `claude/velvet-rope-gate-4a-hcp9wv`)
`gate-4b-review/README.md`, `gate-4b-review/migration_forward.sql`,
`gate-4b-review/migration_rollback.sql`, `gate-4b-review/snapshots_and_reconciliation.sql`,
`gate-4b-review/tests.sql`, `gate-4b-review/base44_app_diffs.md`.
(Gate 4A package remains under `gate-4a-review/`.)

## Apply instructions (from the real app repo / Base44 staging — when authorized)
1. **DB migration (Supabase staging `jioqmxaalxsdlpluzicp`):** run `snapshots_and_reconciliation.sql` §1,
   then `migration_forward.sql` (optionally enable the backfill block), then §2 reconciliation
   (expect 0 mismatches), then the two-session concurrency check. Rollback = `migration_rollback.sql`.
   Name it `20260801_gate4b_reservation_total_spend`. **Never** target production `oihrfwxycbalncsijtfs`.
2. **App changes (Base44 staging app `6a544b88477aac7d84f03509`, or the real app git repo):** apply
   `base44_app_diffs.md` — Priority 1 (dashboard modal) first, then Priority 2. Rebuild + lint/type-check.
   Publish to **staging only**. Record previous/new bundle + function versions.
3. **Then** run the deferred Phase 9 regression and Phase 10 mock night on the Neon Room mock venue.

## Credential / session prerequisites for real browser certification
- A **staff login session** for the staging app `preview--velvet-rope-staging.base44.app` for at least an
  `owner` and a `manager` for the Neon Room venue (e.g. `mocknight+owner1@velvetropehq.com`,
  `mocknight+manager1@velvetropehq.com`) — password/OTP not available to this session — or another way to
  invoke supaProxy as an authenticated staff user.
- A `server`/`cashier` login for POS order/close flows; a `host`/`door` login for check-in/seating.
- Ability to publish the Base44 staging app and apply the Supabase migration (staging only).

---

**REVIEW PACKAGE COMPLETE — AUTHENTICATED BROWSER CERTIFICATION DEFERRED**

Staging remains unchanged. Production remains untouched. No deployment occurred.
