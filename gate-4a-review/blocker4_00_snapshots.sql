-- =====================================================================================
-- Gate 4A · Blocker 4 · PRE-MIGRATION SNAPSHOTS (run BEFORE blocker4_10_forward.sql)
-- Target: STAGING jioqmxaalxsdlpluzicp only.  Uniquely suffixed _g4a_20260731 to avoid collisions.
-- Nothing here is destructive; it only records current state for rollback + reconciliation.
-- =====================================================================================

-- 1a. Schema / function / trigger definition snapshot (text capture of the CURRENT objects).
CREATE TABLE IF NOT EXISTS public._g4a_20260731_objsnap (
  captured_at timestamptz NOT NULL DEFAULT now(),
  obj_kind    text NOT NULL,
  obj_name    text NOT NULL,
  definition  text NOT NULL
);

INSERT INTO public._g4a_20260731_objsnap (obj_kind, obj_name, definition)
SELECT 'function', p.proname, pg_get_functiondef(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('pos_writeback_to_reservation','mirror_legacy_reservation_status');

INSERT INTO public._g4a_20260731_objsnap (obj_kind, obj_name, definition)
SELECT 'trigger', t.tgname, pg_get_triggerdef(t.oid)
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'orders' AND t.tgname = 'trg_pos_writeback' AND NOT t.tgisinternal;

INSERT INTO public._g4a_20260731_objsnap (obj_kind, obj_name, definition)
SELECT 'index', i.indexname, i.indexdef
FROM pg_indexes i
WHERE i.schemaname = 'public' AND i.tablename = 'orders' AND i.indexdef ILIKE '%reservation_id%';

-- 1b. Fresh, uniquely named DATA snapshot of the reservation columns this migration can change.
--     Used by blocker4_30_reconcile.sql to prove the forward migration only changed rows it should.
CREATE TABLE IF NOT EXISTS public._g4a_20260731_res_datasnap AS
SELECT id,
       venue_id,
       total_spend,
       pos_total_amount,
       pos_bill_status,
       pos_closed_at,
       now() AS snapshot_at
FROM public.reservations;

-- 1c. Row counts for the reconciliation report.
SELECT 'reservations_total'      AS metric, count(*) AS value FROM public.reservations
UNION ALL SELECT 'orders_total',            count(*) FROM public.orders
UNION ALL SELECT 'orders_closed',           count(*) FROM public.orders WHERE status = 'closed'
UNION ALL SELECT 'orders_closed_linked',    count(*) FROM public.orders WHERE status = 'closed' AND reservation_id IS NOT NULL;
