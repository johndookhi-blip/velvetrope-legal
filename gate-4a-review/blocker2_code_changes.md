# Blocker 2 — Reservation status writes → `reservation_status` exclusively

**Repository of record:** Base44 app `6a544b88477aac7d84f03509` (Velvet Rope Staging).
**Status:** diffs prepared for owner review — **NOT applied** (editing Base44 source would deploy).

## Why the DB layer needs no change
The mirror trigger is already correct and stays as-is:

```
mirror_legacy_reservation_status():  NEW.status := NEW.reservation_status   -- BEFORE INSERT/UPDATE on reservations
```

Because it runs `BEFORE`, it has a critical consequence that drives this audit:

- A write that sets **only** legacy `status` (no `reservation_status`) is **silently reverted** — the
  trigger overwrites `NEW.status` back to the unchanged `NEW.reservation_status`. Such a write is a
  no-op on UPDATE and forces the column default on INSERT. **These are latent bugs.**
- A write that sets **both** produces the same row the canonical-only write would (redundant, not wrong).

So the fix is: (a) fix every **status-only** reservation write (correctness), and (b) drop the redundant
legacy `status` from **dual** writes so `reservation_status` is the sole writer (exclusivity mandate).

## Classification legend
- **DB-WRITE** = a PATCH/POST/`patch()` body sent to the `reservations` table → **must change**.
- **LOCAL-STATE** = a React `setState`/optimistic object, not a DB write → optional cleanup, no behavior
  impact; listed for completeness. Reads (`select=...status`) are unchanged — the mirror keeps `status`
  populated for legacy readers.

---

## A. Status-ONLY reservation writes (latent bugs — MUST FIX)

### A1. `src/components/dashboard/NewReservationModal.jsx` (~line 20-26) — DB-WRITE, create
This create sets `status` with **no** `reservation_status`, so every reservation it makes is forced to
the column default (`reservation_status='pending'`) and the intended `'confirmed'` is lost.
```diff
       body: JSON.stringify({
         venue_id: venueId,
         guest_name: form.guest_name.trim(),
         party_size: parseInt(form.party_size),
         reservation_time: form.reservation_time || null,
         notes: form.notes || null,
-        status: 'confirmed',
+        reservation_status: 'confirmed',
         // Service-role creator auto-owns the guest they book.
         ...creatorOwnership(),
       }),
```
> NOTE: this component also writes `reservation_time` (the table column is `arrival_time`) and appears to
> be a legacy duplicate of `src/components/reservations/NewReservationModal.jsx`. Flag for owner: confirm
> it is still wired in; if dead, delete it instead. The one-line fix above is the minimal correctness fix.

---

## B. DUAL writes (redundant legacy `status` — drop it for exclusivity)

### B1. `base44/functions/aiConcierge/entry.ts:640` — DB-WRITE (service role), cancel
```diff
-      await db(`reservations?id=eq.${ctx.reservation_id}`, { method: 'PATCH', body: { status: 'canceled', reservation_status: 'canceled' } }).catch(() => {});
+      await db(`reservations?id=eq.${ctx.reservation_id}`, { method: 'PATCH', body: { reservation_status: 'canceled' } }).catch(() => {});
```

### B2. `base44/functions/inboundSms/entry.ts:611` — DB-WRITE (service role), cancel
```diff
-        await db(`reservations?id=eq.${ctx.reservation_id}`, { method: 'PATCH', body: { status: 'canceled', reservation_status: 'canceled' } }).catch(() => {});
+        await db(`reservations?id=eq.${ctx.reservation_id}`, { method: 'PATCH', body: { reservation_status: 'canceled' } }).catch(() => {});
```

### B3. `src/components/reservations/NewReservationModal.jsx` (~line 133) — DB-WRITE, create
```diff
       notes:                form.notes || null,
-      status:               form.status || 'pending',
       reservation_status:   form.status || 'pending',
       deposit_status:       depositAmt && depositAmt > 0 ? 'pending' : 'not_required',
```

### B4. `src/components/dashboard/QuickAddReservationModal.jsx:57` — DB-WRITE, create
```diff
           arrival_time:       arrivalISO,
-          status:             'pending',
           reservation_status: 'pending',
           notes:              form.notes.trim() || null,
```

### B5. `src/components/door/IDCheckInPanel.jsx:39` — DB-WRITE, arrival check-in
```diff
-    await patch({ reservation_status: 'arrived', status: 'arrived', checked_in_at: now, ...(r.arrived_at ? {} : { arrived_at: now }) });
+    await patch({ reservation_status: 'arrived', checked_in_at: now, ...(r.arrived_at ? {} : { arrived_at: now }) });
```
`src/components/door/IDCheckInPanel.jsx:48-49` — same object, drop the `status: 'arrived',` line.

### B6. `src/components/dashboard/CommandDashboardTabs.jsx:306` — DB-WRITE, arrived
```diff
-    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'arrived', status: 'arrived' }) }).catch(() => {
+    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'arrived' }) }).catch(() => {
```
### B7. `src/components/dashboard/CommandDashboardTabs.jsx:323` — DB-WRITE, seated
```diff
-    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'seated', status: 'seated' }) }).catch(() => {
+    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'seated' }) }).catch(() => {
```
Lines 304 & 321 (`optimisticUpdate(..., { ... status: ... })`) are LOCAL-STATE — optional.

### B8. `src/pages/POS.jsx:221` — DB-WRITE, seated
```diff
-          body: JSON.stringify({ reservation_status: 'seated', status: 'seated', ...extra }),
+          body: JSON.stringify({ reservation_status: 'seated', ...extra }),
```
Line 224 (`setReservation(...)`) is LOCAL-STATE — optional.

### B9. `src/pages/Reservations.jsx:262` — DB-WRITE, completed
```diff
-        body: JSON.stringify({ reservation_status: 'completed', status: 'completed' }),
+        body: JSON.stringify({ reservation_status: 'completed' }),
```
### B10. `src/pages/Reservations.jsx:297` — DB-WRITE, no_show
```diff
-    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'no_show', status: 'no_show', ...depositPatch, ...ts }) }).catch(...)
+    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'no_show', ...depositPatch, ...ts }) }).catch(...)
```
Lines 266 & 298 are LOCAL-STATE — optional.

### B11. `src/pages/FloorPlan.jsx:309` — DB-WRITE, seat via floor plan
```diff
-    const body = { table_id: tableId, reservation_status: 'seated', status: 'seated' };
+    const body = { table_id: tableId, reservation_status: 'seated' };
```

### B12. `src/pages/DoorMode.jsx:646` — DB-WRITE, arrived
```diff
-    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'arrived', status: 'arrived', arrived_at: now }) }).catch(() => {});
+    await supaFetch(`reservations?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ reservation_status: 'arrived', arrived_at: now }) }).catch(() => {});
```
Line 647 (`setTonightRes(...)`) is LOCAL-STATE — optional.

---

## C. Already canonical-exclusive (no change) — confirmation sample
These supported reservation writes already write `reservation_status` only:
`base44/functions/create-public-reservation/entry.ts:186` (public booking create),
`base44/functions/scanQRCode/entry.ts:359,392,448` (door arrival),
`base44/functions/aiConcierge/entry.ts:535` & `inboundSms/entry.ts:513` (create),
`src/components/reservations/WalkInModal.jsx:37` (walk-in),
`src/functions/processPaymentCompletion.js:142,187` (payment→confirmed),
`src/pages/HostDoorMode.jsx:56-57` (host seat/arrive),
`src/pages/DoorMode.jsx:285` (local),
`base44/functions/seedDemoData/entry.ts` (seed; INSERT → mirror sets `status`).

## D. Explicitly OUT OF SCOPE (not reservation records — do NOT touch)
`status`/`payment_status`/`deposit_status`/`payout_status` on: `orders`, `payments`, `squad_members`,
`ticket_orders`, `service_requests`, `settlements` (`src/pages/Settlements.jsx:460`), `comps`
(`src/pages/CompManager.jsx:70`), `expenses`, `events`, hookah sessions. These are distinct entities'
own status columns and are unrelated to the reservation `status`/`reservation_status` pair.

## Post-change proof obligation
After applying A+B, grep must return **zero** reservation writes that set `status` without
`reservation_status`, and zero reservation PATCH/POST bodies containing a bare `status:` key. Section A
removes the only status-only path (A1); section B removes every redundant dual write.
