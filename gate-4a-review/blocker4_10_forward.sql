-- =====================================================================================
-- Gate 4A · Blocker 4 · FORWARD migration (concurrency-safe POS writeback + total_spend)
-- Target: Supabase STAGING project jioqmxaalxsdlpluzicp (velvet-rope-staging) ONLY.
-- DO NOT APPLY to production (oihrfwxycbalncsijtfs). Review first. Run 00_snapshots.sql before this.
-- Wrap the whole file in an explicit transaction when applying:
--   BEGIN; \i blocker4_10_forward.sql  -- (inspect) -- COMMIT;  or ROLLBACK;
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Supporting index (verified absent on staging: no index on orders.reservation_id).
--    Partial composite index serves the aggregate  WHERE reservation_id = ? AND status='closed'
--    and the FOR UPDATE parent lookups. Created by THIS sprint => eligible for index rollback.
-- -------------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_orders_reservation_id_status
  ON public.orders (reservation_id, status)
  WHERE reservation_id IS NOT NULL;

-- -------------------------------------------------------------------------------------
-- 2. Rewritten writeback function.
--    * Explicit TG_OP branches (INSERT=NEW only, UPDATE=OLD+NEW, DELETE=OLD only, returns OLD).
--    * total_spend = SUM over CLOSED orders of (subtotal+tax+gratuity+service_charge-discount-comp),
--      each order floored at 0; zero when no eligible orders remain.
--    * Parent reservation row(s) locked FOR UPDATE in ascending-UUID order BEFORE aggregating,
--      so simultaneous order closes on one reservation serialize and cannot leave a stale total,
--      and a (currently guard-blocked) reassignment locking two rows is deadlock-free.
--    * Legacy pos_total_amount / pos_bill_status / pos_closed_at first-close stamp preserved verbatim.
--    * NO global EXCEPTION WHEN OTHERS: a writeback failure now fails the order write (consistency).
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_writeback_to_reservation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res_ids            uuid[];
  v_rid                uuid;
  v_total              numeric;
  v_is_close_transition boolean := false;
  v_close_net          numeric;
BEGIN
  -- ---- (a) Fast-path exit: skip ops that cannot change any closed-order aggregate ----
  IF TG_OP = 'INSERT' THEN
    IF NEW.reservation_id IS NULL OR NEW.status IS DISTINCT FROM 'closed' THEN
      RETURN NEW;
    END IF;
    v_res_ids := ARRAY[NEW.reservation_id];

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.reservation_id IS NULL OR OLD.status IS DISTINCT FROM 'closed' THEN
      RETURN OLD;
    END IF;
    v_res_ids := ARRAY[OLD.reservation_id];

  ELSE  -- UPDATE
    IF NOT (
         (NEW.status IS DISTINCT FROM OLD.status)                     -- open<->close transition
      OR (NEW.reservation_id IS DISTINCT FROM OLD.reservation_id)     -- (guarded) reassignment / first link
      OR (OLD.status = 'closed' AND (                                 -- post-close financial adjustment
             NEW.subtotal             IS DISTINCT FROM OLD.subtotal
          OR NEW.tax_amount           IS DISTINCT FROM OLD.tax_amount
          OR NEW.gratuity_amount      IS DISTINCT FROM OLD.gratuity_amount
          OR NEW.service_charge_amount IS DISTINCT FROM OLD.service_charge_amount
          OR NEW.discount_amount      IS DISTINCT FROM OLD.discount_amount
          OR NEW.comp_amount          IS DISTINCT FROM OLD.comp_amount))
    ) THEN
      RETURN NEW;
    END IF;
    v_res_ids := ARRAY[OLD.reservation_id, NEW.reservation_id];

    IF NEW.status = 'closed'
       AND OLD.status IS DISTINCT FROM 'closed'
       AND NEW.reservation_id IS NOT NULL THEN
      v_is_close_transition := true;
    END IF;
  END IF;

  -- ---- (b) Reduce to DISTINCT, NON-NULL reservation ids, ascending (deterministic lock order) ----
  SELECT array_agg(rid ORDER BY rid)
    INTO v_res_ids
  FROM (SELECT DISTINCT u.rid FROM unnest(v_res_ids) AS u(rid) WHERE u.rid IS NOT NULL) d;

  IF v_res_ids IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  -- ---- (c) Lock parents FIRST, in ascending id order (serialize concurrent closes; deadlock-free) ----
  FOREACH v_rid IN ARRAY v_res_ids LOOP
    PERFORM 1 FROM public.reservations WHERE id = v_rid FOR UPDATE;
  END LOOP;

  -- ---- (d) Recompute aggregate total_spend for each affected reservation ----
  FOREACH v_rid IN ARRAY v_res_ids LOOP
    SELECT COALESCE(SUM(GREATEST(
                COALESCE(o.subtotal,0)              + COALESCE(o.tax_amount,0)
              + COALESCE(o.gratuity_amount,0)       + COALESCE(o.service_charge_amount,0)
              - COALESCE(o.discount_amount,0)       - COALESCE(o.comp_amount,0), 0)), 0)
      INTO v_total
    FROM public.orders o
    WHERE o.reservation_id = v_rid
      AND o.status = 'closed';

    UPDATE public.reservations
       SET total_spend = v_total
     WHERE id = v_rid
       AND total_spend IS DISTINCT FROM v_total;
  END LOOP;

  -- ---- (e) Preserve legacy pos_total_amount FIRST-CLOSE stamp (single order, close transition only) ----
  IF v_is_close_transition THEN
    v_close_net := GREATEST(
        COALESCE(NEW.subtotal,0)               + COALESCE(NEW.tax_amount,0)
      + COALESCE(NEW.gratuity_amount,0)        + COALESCE(NEW.service_charge_amount,0)
      - COALESCE(NEW.discount_amount,0)        - COALESCE(NEW.comp_amount,0), 0);

    UPDATE public.reservations
       SET pos_total_amount = v_close_net,
           pos_bill_status  = 'closed',
           pos_closed_at    = now()
     WHERE id = NEW.reservation_id
       AND pos_bill_status IS DISTINCT FROM 'closed';   -- first close only (unchanged legacy behavior)
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- -------------------------------------------------------------------------------------
-- 3. Re-wire the trigger: was AFTER UPDATE only -> now AFTER INSERT OR UPDATE OR DELETE.
--    The function branches on TG_OP internally, so a single trigger covers all three ops.
-- -------------------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_pos_writeback ON public.orders;
CREATE TRIGGER trg_pos_writeback
  AFTER INSERT OR UPDATE OR DELETE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_writeback_to_reservation();

-- NOTE (Blocker 2): the reservation status mirror trigger is intentionally UNCHANGED:
--   mirror_legacy_reservation_status():  NEW.status := NEW.reservation_status  (BEFORE INSERT/UPDATE)
-- It stays the canonical->legacy mirror. No SQL change for Blocker 2 in the database layer.
