-- =====================================================================================
-- Gate 4B · FORWARD migration — reservation total_spend automation
-- Target: Supabase STAGING project jioqmxaalxsdlpluzicp ONLY.  DO NOT apply to production.
-- Status: PREPARED, NOT APPLIED.  Certified in a rolled-back transaction (see tests.sql).
-- Suggested migration name: 20260801_gate4b_reservation_total_spend
-- Apply wrapped in a transaction:  BEGIN; \i migration_forward.sql  -- inspect --  COMMIT|ROLLBACK;
-- Run snapshots.sql (section 1) BEFORE this.
-- =====================================================================================

-- 1. Supporting index (verified absent on staging). Serves the closed-order aggregate and FOR UPDATE.
CREATE INDEX IF NOT EXISTS idx_orders_reservation_id_status
  ON public.orders (reservation_id, status) WHERE reservation_id IS NOT NULL;

-- 2. Reusable, idempotent, concurrency-safe recalculator for a SINGLE reservation.
--    Contract: total_spend = SUM over CLOSED orders of
--      (subtotal + tax_amount + gratuity_amount + service_charge_amount - discount_amount - comp_amount),
--    each order floored at 0; 0 when no eligible orders; NULL arg -> NULL (no-op).
--    Locks the reservation row FOR UPDATE so concurrent recalcs serialize (no stale total).
CREATE OR REPLACE FUNCTION public.recalculate_reservation_total_spend(p_reservation_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_total numeric;
BEGIN
  IF p_reservation_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Serialize concurrent recalculations for this reservation (deadlock-free when the caller
  -- locks multiple reservations in ascending id order — see pos_writeback_to_reservation()).
  PERFORM 1 FROM public.reservations WHERE id = p_reservation_id FOR UPDATE;

  SELECT COALESCE(SUM(GREATEST(
             COALESCE(o.subtotal,0)              + COALESCE(o.tax_amount,0)
           + COALESCE(o.gratuity_amount,0)       + COALESCE(o.service_charge_amount,0)
           - COALESCE(o.discount_amount,0)       - COALESCE(o.comp_amount,0), 0)), 0)
    INTO v_total
  FROM public.orders o
  WHERE o.reservation_id = p_reservation_id
    AND o.status = 'closed';

  UPDATE public.reservations
     SET total_spend = v_total
   WHERE id = p_reservation_id
     AND total_spend IS DISTINCT FROM v_total;   -- idempotent: no write when unchanged

  RETURN v_total;
END;
$fn$;

-- 3. Trigger function: explicit TG_OP branches, recalculates OLD+NEW reservations on reassignment,
--    locks affected reservations in ascending-UUID order (via the recalc fn), no swallowed exceptions,
--    preserves the legacy pos_total_amount first-close stamp verbatim.
CREATE OR REPLACE FUNCTION public.pos_writeback_to_reservation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $tg$
DECLARE
  v_ids       uuid[];
  v_rid       uuid;
  v_close_net numeric;
BEGIN
  -- Fast-path exit for ops that cannot change any closed-order aggregate.
  IF TG_OP = 'INSERT' THEN
    IF NEW.reservation_id IS NULL OR NEW.status IS DISTINCT FROM 'closed' THEN RETURN NEW; END IF;
    v_ids := ARRAY[NEW.reservation_id];

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.reservation_id IS NULL OR OLD.status IS DISTINCT FROM 'closed' THEN RETURN OLD; END IF;
    v_ids := ARRAY[OLD.reservation_id];

  ELSE  -- UPDATE
    IF NOT (
         (NEW.status IS DISTINCT FROM OLD.status)
      OR (NEW.reservation_id IS DISTINCT FROM OLD.reservation_id)
      OR (OLD.status = 'closed' AND (
             NEW.subtotal             IS DISTINCT FROM OLD.subtotal
          OR NEW.tax_amount           IS DISTINCT FROM OLD.tax_amount
          OR NEW.gratuity_amount      IS DISTINCT FROM OLD.gratuity_amount
          OR NEW.service_charge_amount IS DISTINCT FROM OLD.service_charge_amount
          OR NEW.discount_amount      IS DISTINCT FROM OLD.discount_amount
          OR NEW.comp_amount          IS DISTINCT FROM OLD.comp_amount))
    ) THEN
      RETURN NEW;
    END IF;
    v_ids := ARRAY[OLD.reservation_id, NEW.reservation_id];
  END IF;

  -- DISTINCT, NON-NULL, ascending id order -> deterministic lock acquisition (deadlock-free).
  SELECT array_agg(rid ORDER BY rid) INTO v_ids
  FROM (SELECT DISTINCT u.rid FROM unnest(v_ids) AS u(rid) WHERE u.rid IS NOT NULL) d;

  IF v_ids IS NOT NULL THEN
    FOREACH v_rid IN ARRAY v_ids LOOP
      PERFORM public.recalculate_reservation_total_spend(v_rid);
    END LOOP;
  END IF;

  -- Preserve legacy pos_total_amount FIRST-CLOSE stamp (single order, close transition only).
  IF TG_OP = 'UPDATE'
     AND NEW.status = 'closed'
     AND OLD.status IS DISTINCT FROM 'closed'
     AND NEW.reservation_id IS NOT NULL THEN
    v_close_net := GREATEST(
        COALESCE(NEW.subtotal,0)               + COALESCE(NEW.tax_amount,0)
      + COALESCE(NEW.gratuity_amount,0)        + COALESCE(NEW.service_charge_amount,0)
      - COALESCE(NEW.discount_amount,0)        - COALESCE(NEW.comp_amount,0), 0);
    UPDATE public.reservations
       SET pos_total_amount = v_close_net, pos_bill_status = 'closed', pos_closed_at = now()
     WHERE id = NEW.reservation_id AND pos_bill_status IS DISTINCT FROM 'closed';
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$tg$;

-- 4. Re-wire the trigger: was AFTER UPDATE only -> AFTER INSERT OR UPDATE OR DELETE.
DROP TRIGGER IF EXISTS trg_pos_writeback ON public.orders;
CREATE TRIGGER trg_pos_writeback
  AFTER INSERT OR UPDATE OR DELETE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.pos_writeback_to_reservation();

-- 5. OPTIONAL one-time backfill of existing reservations (safe, idempotent). Uncomment to run.
--    Recomputes total_spend for every reservation that currently has closed orders or a non-zero total.
-- DO $backfill$
-- DECLARE rid uuid;
-- BEGIN
--   FOR rid IN
--     SELECT DISTINCT reservation_id FROM public.orders WHERE reservation_id IS NOT NULL AND status='closed'
--     UNION
--     SELECT id FROM public.reservations WHERE total_spend IS DISTINCT FROM 0
--   LOOP
--     PERFORM public.recalculate_reservation_total_spend(rid);
--   END LOOP;
-- END;
-- $backfill$;

-- NOTE: the reservation status mirror is intentionally UNCHANGED:
--   mirror_legacy_reservation_status(): NEW.status := NEW.reservation_status  (BEFORE INS/UPD on reservations)
