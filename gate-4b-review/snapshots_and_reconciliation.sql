-- =====================================================================================
-- Gate 4B · PRE-MIGRATION SNAPSHOTS + POST-MIGRATION RECONCILIATION.  STAGING only.
-- =====================================================================================

-- ===== SECTION 1 — PRE-MIGRATION SNAPSHOT (run BEFORE migration_forward.sql) =====
CREATE TABLE IF NOT EXISTS public._g4b_snap_objects (
  captured_at timestamptz NOT NULL DEFAULT now(), obj_kind text, obj_name text, definition text);
INSERT INTO public._g4b_snap_objects(obj_kind,obj_name,definition)
SELECT 'function', p.proname, pg_get_functiondef(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('pos_writeback_to_reservation','mirror_legacy_reservation_status');
INSERT INTO public._g4b_snap_objects(obj_kind,obj_name,definition)
SELECT 'trigger', t.tgname, pg_get_triggerdef(t.oid)
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname='orders' AND t.tgname='trg_pos_writeback' AND NOT t.tgisinternal;

CREATE TABLE IF NOT EXISTS public._g4b_snap_reservations AS
SELECT id, venue_id, total_spend, pos_total_amount, pos_bill_status, pos_closed_at, now() AS snapshot_at
FROM public.reservations;

SELECT 'reservations' m, count(*) v FROM public.reservations
UNION ALL SELECT 'orders_closed_linked', count(*) FROM public.orders WHERE status='closed' AND reservation_id IS NOT NULL;

-- ===== SECTION 2 — POST-MIGRATION VALIDATION / RECONCILIATION (run AFTER migration + backfill) =====
-- R1. Independent recompute vs stored total_spend. Expect ZERO rows.
WITH expected AS (
  SELECT r.id AS reservation_id,
         COALESCE(SUM(GREATEST(
             COALESCE(o.subtotal,0)+COALESCE(o.tax_amount,0)+COALESCE(o.gratuity_amount,0)
           + COALESCE(o.service_charge_amount,0)-COALESCE(o.discount_amount,0)-COALESCE(o.comp_amount,0),0)),0) AS exp
  FROM public.reservations r
  LEFT JOIN public.orders o ON o.reservation_id=r.id AND o.status='closed'
  GROUP BY r.id)
SELECT r.id, r.total_spend AS stored, e.exp AS expected, (r.total_spend-e.exp) AS delta
FROM public.reservations r JOIN expected e ON e.reservation_id=r.id
WHERE r.total_spend IS DISTINCT FROM e.exp
ORDER BY abs(r.total_spend-e.exp) DESC;

-- R2. Change surface vs snapshot: only total_spend should move (pos_* untouched by a pure swap).
SELECT count(*) FILTER (WHERE r.total_spend      IS DISTINCT FROM s.total_spend)      AS total_spend_changed,
       count(*) FILTER (WHERE r.pos_total_amount IS DISTINCT FROM s.pos_total_amount) AS pos_total_amount_changed,
       count(*) FILTER (WHERE r.pos_bill_status  IS DISTINCT FROM s.pos_bill_status)  AS pos_bill_status_changed
FROM public.reservations r JOIN public._g4b_snap_reservations s ON s.id=r.id;

-- R3. Row-count parity.
SELECT (SELECT count(*) FROM public.reservations) AS now_rows,
       (SELECT count(*) FROM public._g4b_snap_reservations) AS snap_rows;

-- ===== SECTION 3 — CLEANUP (only after certification) =====
-- DROP TABLE IF EXISTS public._g4b_snap_objects;
-- DROP TABLE IF EXISTS public._g4b_snap_reservations;
