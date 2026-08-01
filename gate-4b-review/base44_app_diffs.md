# Gate 4B — Base44 application diffs (staging app `6a544b88477aac7d84f03509`)

**Status:** PREPARED, **NOT applied / NOT deployed.** Apply these in the *actual Velvet Rope app
repository* or directly in the Base44 staging app (see `README.md` §Apply instructions). Editing Base44
source deploys it, so it was deliberately not done here.

The DB reservation-status mirror is correct and stays: `mirror_legacy_reservation_status()` runs BEFORE
INSERT/UPDATE and sets `NEW.status := NEW.reservation_status`. Because it runs BEFORE, a **status-only**
write is silently reverted — that is the class of defect fixed below.

---

## PRIORITY 1 — the reproduced create failure
### `src/components/dashboard/NewReservationModal.jsx` (submit body, ~lines 18-27)

Two defects in one payload: (a) it sends the `datetime-local` value into `reservation_time`, which is a
`time without time zone` column → PostgREST returns `22007 invalid input syntax for type time` and the
**POST fails**; (b) it is a **status-only** write, so even a valid payload persists `reservation_status`
as the default `pending` instead of the intended `confirmed`.

Reproduced on staging (rolled back):
`INSERT ... (reservation_time,status) VALUES ('2026-08-01T22:00','confirmed')` → `22007` FAIL.
Fixed form `INSERT ... (arrival_time,reservation_status) VALUES ('2026-08-01T22:00','confirmed')` →
persists `reservation_status=confirmed`, mirror `status=confirmed`. ✅

```diff
       body: JSON.stringify({
         venue_id: venueId,
         guest_name: form.guest_name.trim(),
         party_size: parseInt(form.party_size),
-        reservation_time: form.reservation_time || null,
-        notes: form.notes || null,
-        status: 'confirmed',
+        arrival_time: form.reservation_time || null,   // form field is a datetime-local; column is arrival_time (timestamptz).
+        notes: form.notes || null,                     // reservations.reservation_time is time-of-day and must not receive a datetime.
+        reservation_status: 'confirmed',               // canonical field; the BEFORE mirror populates legacy status.
         // Service-role creator auto-owns the guest they book.
         ...creatorOwnership(),
       }),
```
> Also flag for owner: this modal duplicates `src/components/reservations/NewReservationModal.jsx`
> (which is correct and richer). Preferred cleanup is to retire this dashboard variant and route callers
> to the canonical modal. The one-line-per-field fix above is the minimal correctness fix if it stays.

---

## PRIORITY 2 — reservation status-writes → canonical `reservation_status`
(Full rationale/inventory in `../gate-4a-review/blocker2_code_changes.md`; reproduced here so Gate 4B is
self-contained. `DB-WRITE` = must change; `LOCAL-STATE` = optional React-state cleanup.)

### Backend service-role writes
`base44/functions/aiConcierge/entry.ts:640` and `base44/functions/inboundSms/entry.ts:611`:
```diff
- body: { status: 'canceled', reservation_status: 'canceled' }
+ body: { reservation_status: 'canceled' }
```

### Frontend DB writes — drop redundant legacy `status`
```diff
# src/components/reservations/NewReservationModal.jsx  (~line 133, create)
-      status:               form.status || 'pending',
       reservation_status:   form.status || 'pending',

# src/components/dashboard/QuickAddReservationModal.jsx:57  (create)
-          status:             'pending',
           reservation_status: 'pending',

# src/components/door/IDCheckInPanel.jsx:39 (and 48-49)  (arrive)
-    await patch({ reservation_status: 'arrived', status: 'arrived', checked_in_at: now, ...(r.arrived_at ? {} : { arrived_at: now }) });
+    await patch({ reservation_status: 'arrived', checked_in_at: now, ...(r.arrived_at ? {} : { arrived_at: now }) });

# src/components/dashboard/CommandDashboardTabs.jsx:306 (arrive) & :323 (seat)  — PATCH bodies
-      body: JSON.stringify({ reservation_status: 'arrived', status: 'arrived' })
+      body: JSON.stringify({ reservation_status: 'arrived' })
-      body: JSON.stringify({ reservation_status: 'seated', status: 'seated' })
+      body: JSON.stringify({ reservation_status: 'seated' })

# src/pages/POS.jsx:221  (seat)
-          body: JSON.stringify({ reservation_status: 'seated', status: 'seated', ...extra }),
+          body: JSON.stringify({ reservation_status: 'seated', ...extra }),

# src/pages/Reservations.jsx:262 (complete) & :297 (no_show)
-        body: JSON.stringify({ reservation_status: 'completed', status: 'completed' }),
+        body: JSON.stringify({ reservation_status: 'completed' }),
-      body: JSON.stringify({ reservation_status: 'no_show', status: 'no_show', ...depositPatch, ...ts }),
+      body: JSON.stringify({ reservation_status: 'no_show', ...depositPatch, ...ts }),

# src/pages/FloorPlan.jsx:309  (seat)
-    const body = { table_id: tableId, reservation_status: 'seated', status: 'seated' };
+    const body = { table_id: tableId, reservation_status: 'seated' };

# src/pages/DoorMode.jsx:646  (arrive)
-    body: JSON.stringify({ reservation_status: 'arrived', status: 'arrived', arrived_at: now })
+    body: JSON.stringify({ reservation_status: 'arrived', arrived_at: now })
```

**LOCAL-STATE (optional, not DB writes):** `CommandDashboardTabs.jsx:304/321`, `POS.jsx:224`,
`Reservations.jsx:266/298`, `DoorMode.jsx:647` — React optimistic objects carrying `status`. No behavior
impact; may be cleaned to reference `reservation_status`.

**Already canonical (no change):** `create-public-reservation` (public booking), `scanQRCode` (door
arrival), `WalkInModal` (walk-in), `processPaymentCompletion`, `HostDoorMode`, `aiConcierge:535`/
`inboundSms:513` (creates), `seedDemoData`.

**Out of scope (different entities' own status):** `orders`, `payments`, `squad_members`, `ticket_orders`,
`service_requests`, `settlements`, `comps`, `expenses`, `events`.

---

## supaProxy — no change required
`base44/functions/supaProxy/entry.ts` authorizes via `staff_members` (active membership, server-side
`auth.me()` email, venue hard-scoping, deny-by-default matrix, fail-closed). The reproduced create failure
is **not** in supaProxy — it is the client payload defect in Priority 1. `venue_users` remains the dormant
future Supabase-Auth path (DB `auth_venue_role`) and is **left unchanged** (no schema edit).

## Post-change proof obligation
After applying: grep shows zero reservation writes that set `status` without `reservation_status`, zero
`reservation_time` writes carrying a datetime value, and the dashboard modal create returns a row with
`reservation_status='confirmed'`.
