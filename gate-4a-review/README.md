# Velvet Rope — Gate 4A Completion Sprint · Owner Review Package

**Date:** 2026-07-31  · **Author:** takeover from Manus (credits expired)
**Nothing in this sprint has been applied.** All SQL, diffs, and tests are prepared for owner review.
Staging DB objects, the Base44 app, and production were **not** mutated. Tests were executed only inside
transactions that were rolled back (verified: live objects unchanged afterward).

---

## 0. Environment & production isolation (Phase 8 · item 12)

| Role | Base44 app | Supabase project | Touched? |
|------|-----------|------------------|----------|
| **Staging (authorized)** | `6a544b88477aac7d84f03509` (Velvet Rope Staging) | `jioqmxaalxsdlpluzicp` (velvet-rope-staging) | Read + **rolled-back** test txns only |
| **Production (PROHIBITED)** | `69c7a1c934df2c7929973ae8` | `oihrfwxycbalncsijtfs` | **Never accessed** |

Mock venue used for fixtures: `__MOCK_NIGHT__ Neon Room` = `81bcd151-e2a2-4c83-956f-77d8756e5b18`.
Every `execute_sql` in this sprint targeted **only** `jioqmxaalxsdlpluzicp`. Post-run verification:
`pos_writeback_to_reservation` still the original (no `TG_OP`), `trg_pos_writeback` still `AFTER UPDATE`
only, sprint index absent, zero leftover snapshot tables.

---

## 1. Baseline (Phase 1)

- **Git repo `johndookhi-blip/velvetrope-legal`** (this repo) — branch `claude/velvet-rope-gate-4a-hcp9wv`,
  clean tree at start. It contains **only the static legal site** (`index.html`, `/terms`, `/privacy`,
  `/sms-consent`, `CNAME`). **None** of the Gate 4A engineering targets live here — the only matches for
  "reservations/commission/settlement" are prose in the Terms/Privacy pages. This review package is
  committed here (the authorized branch) as the deliverable; it does not affect the served legal pages.
- **Actual application source** lives in the Base44 staging app `6a544b88477aac7d84f03509`
  (`base44/functions/**`, `src/**`, `supabase/migrations/**`) and the staging Postgres schema.

**Files/objects located for the sprint:**

| Concern | Location |
|---|---|
| supaProxy | `base44/functions/supaProxy/entry.ts` (**found**, 394 lines) |
| reservation `status` mirror | DB fn `mirror_legacy_reservation_status` + trigger `trg_mirror_legacy_status` (BEFORE INS/UPD) |
| `reservation_status` state guard | DB fn `guard_reservations_state_transitions_fn` (BEFORE UPD) |
| POS writeback | DB fn `pos_writeback_to_reservation` + trigger `trg_pos_writeback` (AFTER UPDATE only) |
| `total_spend` | `reservations.total_spend` (numeric, default 0) — **no DB maintainer today** |
| `pos_total_amount` | `reservations.pos_total_amount` — stamped by `pos_writeback` first-close; read by `evaluatePayoutEligibility` |
| commissions | DB fns `invoke_commission_on_pos_close`, `enqueue_commission_reversal_on_cancel/_on_deposit_refund`; table `commission_events`; `base44/functions/generateCommission` |
| settlements | tables `settlements`, `settlement_snapshots`, `settlement_history`; `supabase/functions/process-financial-events`, `list-my-earnings` |
| refunds / chargebacks | **No such tables.** Modeled as `financial_reversals` rows (+ `payments`) |

---

## 2. Blocker 2 — caller inventory (Phase 2 · items 2–4)

Canonical field = `reservation_status`; `status` is the legacy mirror. The mirror trigger runs **BEFORE**,
so a **status-only** reservation write is silently reverted — that is the real hazard.

**Complete inventory of reservation-record `status` / `reservation_status` writes** (reads omitted for
brevity; reads rely on the mirror and are unchanged). Full diffs: `blocker2_code_changes.md`.

| # | File | Line | Op | Field(s) written | Must change? |
|---|------|------|----|------------------|--------------|
| 1 | `src/components/dashboard/NewReservationModal.jsx` | ~25 | create | `status` **only** | **YES — status-only bug** → `reservation_status` |
| 2 | `base44/functions/aiConcierge/entry.ts` | 640 | update (cancel) | `status`+`reservation_status` | YES — drop `status` |
| 3 | `base44/functions/inboundSms/entry.ts` | 611 | update (cancel) | `status`+`reservation_status` | YES — drop `status` |
| 4 | `src/components/reservations/NewReservationModal.jsx` | ~133 | create | `status`+`reservation_status` | YES — drop `status` |
| 5 | `src/components/dashboard/QuickAddReservationModal.jsx` | 57 | create | `status`+`reservation_status` | YES — drop `status` |
| 6 | `src/components/door/IDCheckInPanel.jsx` | 39, 48-49 | update (arrive) | `status`+`reservation_status` | YES — drop `status` |
| 7 | `src/components/dashboard/CommandDashboardTabs.jsx` | 306 (arrive), 323 (seat) | update | `status`+`reservation_status` | YES — drop `status` |
| 8 | `src/pages/POS.jsx` | 221 | update (seat) | `status`+`reservation_status` | YES — drop `status` |
| 9 | `src/pages/Reservations.jsx` | 262 (complete), 297 (no_show) | update | `status`+`reservation_status` | YES — drop `status` |
| 10 | `src/pages/FloorPlan.jsx` | 309 | update (seat) | `status`+`reservation_status` | YES — drop `status` |
| 11 | `src/pages/DoorMode.jsx` | 646 | update (arrive) | `status`+`reservation_status` | YES — drop `status` |
| 12 | `CommandDashboardTabs 304/321`, `POS 224`, `Reservations 266/298`, `DoorMode 647` | — | local React state | `status` in `setState` | No (not a DB write) — optional cleanup |
| 13 | `create-public-reservation:186`, `scanQRCode:359/392/448`, `WalkInModal:37`, `processPaymentCompletion:142/187`, `HostDoorMode:56-57`, `aiConcierge:535`, `inboundSms:513`, `seedDemoData` | — | create/update | `reservation_status` only | No — already canonical |
| 14 | orders/payments/squad_members/ticket_orders/service_requests/settlements/comps/expenses `status` | — | — | non-reservation entities | No — out of scope |

**Regression scenarios (all satisfied by the canonical-exclusive writes after the change):**
public booking (#13 create-public-reservation), reservation creation (#1,#4,#5 → all canonical),
walk-in (#13 WalkInModal), door arrival (#6,#11,#13 scanQRCode), manual check-in (#6),
host seating (#13 HostDoorMode), floor seating (#7 seat, #10), cancellation (#2,#3),
no-show (#9), completion (#9 complete; DB also auto-completes via `trg_orders_release_table_on_close`),
promoter-linked reservation (attribution path unaffected — writes are status-agnostic).

**Proof obligation:** after applying §A+§B of `blocker2_code_changes.md`, no supported path writes
reservation `status` without `reservation_status` (only #1 did; it is fixed), and no dual writes remain.

## 3. Blocker 2 — code changes (Phase 8 · item 3)
See **`blocker2_code_changes.md`** — 12 exact diffs (1 status-only correctness fix + 11 dual-write
cleanups). Prepared, **not applied** (editing Base44 source deploys). DB mirror trigger unchanged.

## 4. Blocker 2 — tests (Phase 8 · item 4)
The mirror is a pure assignment (`NEW.status := NEW.reservation_status`); its behavior is covered
indirectly by every Blocker 4 fixture (each inserts/updates `reservation_status` and the rows remain
valid). A focused mirror check to run post-apply:
```sql
-- in a rolled-back txn: prove canonical-only writes populate the legacy mirror
BEGIN;
  INSERT INTO reservations(venue_id,guest_name,reservation_status)
    VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','mirror-test','confirmed') RETURNING status; -- expect 'confirmed'
  UPDATE reservations SET reservation_status='seated'
    WHERE guest_name='mirror-test' RETURNING status;                                            -- expect 'seated'
ROLLBACK;
```

---

## 5. Blocker 4 — financial contract (Phase 3, Phase 8 · item 5)

**Confirmed definition (matches current code; nothing invented):**

> `reservations.total_spend` = the sum, over every **closed** order linked to the reservation, of
> `subtotal + tax_amount + gratuity_amount + service_charge_amount − discount_amount − comp_amount`,
> each order **floored at 0**; **zero** when no closed orders remain.
> **Excludes** deposits (`deposit_applied`), payments (`total_paid`), and all post-close reversals.

**Grounding facts (verified on staging):**
- `orders.status` CHECK = `('open','closed')` — closed is terminal (`guard_orders_no_reopen_fn`);
  an order may only close when fully settled (`guard_orders_no_close_when_unsettled_fn`, remaining ≤ 0.01).
- Generated `orders.total_due = subtotal+tax+gratuity+service_charge−discount−comp−deposit_applied`.
  The contract charge = `total_due + deposit_applied` → deposits are explicitly added back (excluded from
  being treated as a discount). Confirms deposit/payment exclusion.
- `total_spend` currently has **no DB writer** (only `guard_operational_columns` references it, as a
  guard). Today it stays at its default `0`. This is the gap Blocker 4 closes.
- `pos_writeback` today writes only `pos_total_amount` (single closing order's net, first close), not
  `total_spend`.

**Explicit treatment of edge cases (do-not-invent, derived from code + constraints):**

| Case | Treatment | Basis |
|---|---|---|
| Deposit refunds | No effect on `total_spend` | Deposits excluded from charge; `deposit_status='refunded'` only enqueues commission reversal (`enqueue_commission_reversal_on_deposit_refund`) |
| Payment refunds | No effect on `total_spend` | Payments excluded; recorded as `financial_reversals` (`refund_processed`) |
| Partial refunds | No effect on `total_spend` | Same as above; reversal amount is partial |
| Chargebacks | No effect on `total_spend` | `financial_reversals` (`reversal_type='refund_processed'`, `reason='chargeback'`) |
| Post-close voids | No effect on `total_spend` | No `void` order status exists; recorded as `financial_reversals` (`reason='pos_void'`). A closed order is never reopened |
| Manager adjustments (post-close) | **Included** if they change the closed order's charge columns; a `financial_reversals` adjustment row does **not** | Closed order charge is the source of truth; new writeback recomputes on closed-order charge edits (T5) |
| Canceled orders | No `canceled` order status exists → modeled as **row delete** → excluded, `total_spend` recomputed | `orders.status` CHECK |
| Deleted orders | Excluded; `total_spend` recomputed down (to 0 if last) | New DELETE branch |
| Reassigned orders | A→B reassignment is **blocked** by `guard_orders_no_reservation_reassignment_fn` when the order is already linked; only NULL→B first-link occurs, which recomputes B. New writeback still locks/recomputes both sides defensively | guard fn |
| Deposit as bill credit | Lowers `total_due`/remaining, **not** the charge; `total_spend` unchanged | `recompute_order_financials` deposit pool logic + generated `total_due` |

## 6. Blocker 4 — SQL (Phase 8 · item 6)
- `blocker4_00_snapshots.sql` — pre-migration object + data snapshots, row counts (run first).
- `blocker4_10_forward.sql` — index + rewritten `pos_writeback_to_reservation` + trigger rewire.
- `blocker4_30_reconcile.sql` — independent recompute vs stored, change-surface, row-count parity.

## 7. Blocker 4 — concurrency design (Phase 4, Phase 8 · item 7)

Rewritten `pos_writeback_to_reservation` (`blocker4_10_forward.sql`):
- **Explicit `TG_OP` branches:** INSERT uses `NEW` only; UPDATE uses `OLD`+`NEW`; DELETE uses `OLD` only
  and **returns `OLD`**; other paths return `NEW`.
- **No global `EXCEPTION WHEN OTHERS`** — a writeback failure now fails the order write (consistency
  over silent divergence). *This is an intentional behavior change from the old warn-and-continue.*
- **Reassignment:** recomputes both `OLD` and `NEW` reservation ids (deduped, non-null).
- **Zeroing:** `total_spend` = `COALESCE(SUM(...),0)` → **0 when no eligible closed orders remain**.
- **`pos_total_amount` preserved verbatim:** first-close stamp only, `WHERE pos_bill_status IS DISTINCT
  FROM 'closed'`, single closing order's net (no verified defect requires changing it).
- **Locking / no stale totals:** parent reservation row(s) are `SELECT … FOR UPDATE`-locked **before**
  aggregating; when two rows are involved they are locked in **ascending UUID order** → deadlock-free.
  Two concurrent order closes on one reservation serialize on the lock; whichever commits second
  re-aggregates over both now-closed orders → final `total_spend` = sum of both, never a lost update.
- **Index:** `idx_orders_reservation_id_status (reservation_id, status) WHERE reservation_id IS NOT NULL`
  — verified **absent** today, so this sprint creates it (and only this sprint may roll it back).
- **Trigger rewire:** `AFTER UPDATE` → `AFTER INSERT OR UPDATE OR DELETE`; a fast-path exit skips ops
  that cannot change any closed-order aggregate (avoids needless locks on open-order churn).

## 8. Blocker 4 — rollback (Phase 5, Phase 8 · item 8)
`blocker4_20_rollback.sql` restores the **exact** captured original function body, restores the
`AFTER UPDATE`-only trigger, and drops the sprint index (only because this sprint created it).
`blocker4_50_cleanup.sql` drops the snapshot tables **after certification**. Migrations are **not**
applied until the package is reviewed.

## 9. Test results (Phase 6, Phase 8 · item 9)

Executed against staging **inside a single transaction that was rolled back** (forward migration created,
all fixtures run, `ROLLBACK`; live objects verified unchanged afterward). **14/14 scenario groups PASS.**

| Scenario | Expected | Got | Pass |
|---|---|---|---|
| T1 no orders | 0 | 0 | ✅ |
| T2 open order excluded | 0 | 0 | ✅ |
| T3 one closed | 133 | 133 | ✅ |
| T4 second closed (aggregate) | 154 | 154 | ✅ |
| T5 post-close total edit (mgr adj on closed order) | 200→215 | 200→215 | ✅ |
| T6 discount | 70 | 70 | ✅ |
| T7 comp | 0 | 0 | ✅ |
| T8/T9 gratuity + service charge | 130 | 130 | ✅ |
| T10/T11/T12 deposit + partial + full payment excluded | 100 | 100 | ✅ |
| T13/T14 delete (void/cancel) closed order | 140→100 | 140→100 | ✅ |
| T15 delete last closed → 0 | 0 | 0 | ✅ |
| T16 A→B reassignment guard-blocked | blocked | blocked | ✅ |
| T17/T18/T19 refund + chargeback-class + manager adjustment excluded | 100/100/100 | 100/100/100 | ✅ |
| T20 multi-order (2 closed + 1 open) | 316 | 316 | ✅ |
| T21 open→close transition + `pos_total_amount` stamp | ts=120, pta=120, pbs=closed | same | ✅ |

**Concurrency test (T22):** two-session procedure documented in `blocker4_40_tests.sql` (cannot run in a
single autocommit session). Expected final `total_spend` = sum of both closed orders (e.g. 100+150=**250**),
guaranteed by the `FOR UPDATE` serialization. **Owner to run in two psql sessions post-approval.**

## 10. supaProxy source result (Phase 7, Phase 8 · item 10)

**FOUND** — `base44/functions/supaProxy/entry.ts` (394 lines). It **already implements the required
staff_members-based authorization**; there is **no `venue_users` authorization to migrate** in supaProxy.

Authorization contract compliance (as written in the committed staging source):
- **Trusted authenticated email:** `user = await base44.auth.me()` (server-side). Client-supplied email is
  **never** trusted — membership is resolved by `user.email`, not by request body. ✅
- **Active membership:** `staff_members?email=eq.<user.email>&is_active=eq.true&select=role,venue_id`. ✅
- **Matching venue:** path `venue_id` mismatch → 403; foreign body `venue_id` → 403; venue-scoped tables
  hard-scoped via injected `venue_id=in.(memberVenues)`; create must name a member venue. ✅
- **Permission decision:** `decide(role, table, op)` matrix; writes deny-by-default; sensitive
  reservations payout/POS columns require owner/manager. ✅
- **Fail closed:** unresolved membership → 403; no membership → 403; unknown verb → 400; any thrown
  error → 500 without proxying. ✅
- **Future Supabase Auth path preserved:** `venue_users` remains only in the DB layer
  (`auth_venue_role(p_venue)` → `venue_users.user_id = auth.uid()`), untouched — consistent with
  Blocker 3 (staff_members = Base44 auth source; venue_users = UUID-based future path).

**Comparison to reported deployed behavior (Blocker 1):** the reported blocker was "create authorization
blocked pending the exact deployed staging source." The committed staging source shown above **already**
enforces create authorization via `staff_members` with a fail-closed contract, including the specific
create rule *"CREATE on a venue-scoped table MUST name a member venue in every row"* (§3 of the proxy).
The one thing source cannot self-certify is whether the **running deployed function bytes** equal this
committed source. That equality is the outstanding confirmation.

**Prepared staff_members auth diff:** **none required** — the source already conforms; no `venue_users`
authorization exists in supaProxy to replace. No deployment performed.

## 11. Files changed / created (Phase 8 · item 11)

**Created in this git branch (review artifacts only — no app/runtime change):**
- `gate-4a-review/README.md` (this file)
- `gate-4a-review/blocker2_code_changes.md`
- `gate-4a-review/blocker4_00_snapshots.sql`
- `gate-4a-review/blocker4_10_forward.sql`
- `gate-4a-review/blocker4_20_rollback.sql`
- `gate-4a-review/blocker4_30_reconcile.sql`
- `gate-4a-review/blocker4_40_tests.sql`
- `gate-4a-review/blocker4_50_cleanup.sql`

**Prepared for the Base44 staging app (NOT applied):** the 12 diffs in `blocker2_code_changes.md`
(`base44/functions/aiConcierge`, `base44/functions/inboundSms`, `src/components/**`, `src/pages/**`).

**Prepared for staging Postgres (NOT applied):** the migration in `blocker4_10_forward.sql`
(function `pos_writeback_to_reservation`, trigger `trg_pos_writeback`, index
`idx_orders_reservation_id_status`).

## 12. Production isolation (Phase 8 · item 12)
Confirmed — see §0. Production Base44 `69c7a1c934df2c7929973ae8` and Supabase `oihrfwxycbalncsijtfs`
were never accessed. All work targeted staging `jioqmxaalxsdlpluzicp`, and every mutation ran in a
rolled-back transaction, verified afterward to have left the live schema unchanged.

---

## Outstanding item
Blocker 1 requires confirmation that the **running deployed** supaProxy equals the committed staging
source (the source is present and already conforms; only deploy-equality is unverifiable from source).
Given the source is found and compliant, this package proceeds to owner review rather than blocking.
