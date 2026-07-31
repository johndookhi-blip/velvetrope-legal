-- =====================================================================================
-- Gate 4A · Blocker 4 · ROLLBACK (restores the EXACT pre-sprint deployed state)
-- Target: STAGING jioqmxaalxsdlpluzicp only. Reverses blocker4_10_forward.sql completely.
-- =====================================================================================

-- 1. Restore the trigger to its pre-sprint wiring: AFTER UPDATE only.
DROP TRIGGER IF EXISTS trg_pos_writeback ON public.orders;
CREATE TRIGGER trg_pos_writeback
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_writeback_to_reservation();

-- 2. Restore the ORIGINAL function body verbatim (as captured from staging on 2026-07-31).
CREATE OR REPLACE FUNCTION public.pos_writeback_to_reservation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_total numeric;
begin
  begin
    if new.status = 'closed'
       and old.status is distinct from 'closed'
       and new.reservation_id is not null then
      v_total := greatest(
        coalesce(new.subtotal,0) + coalesce(new.tax_amount,0) + coalesce(new.gratuity_amount,0)
        + coalesce(new.service_charge_amount,0) - coalesce(new.discount_amount,0) - coalesce(new.comp_amount,0),
        0);
      update public.reservations
         set pos_total_amount = v_total,
             pos_bill_status  = 'closed',
             pos_closed_at    = now()
       where id = new.reservation_id
         and pos_bill_status is distinct from 'closed';  -- first close only
    end if;
  exception when others then
    raise warning 'pos_writeback_to_reservation failed for order %: %', new.id, sqlerrm;
  end;
  return new;
end;
$function$;

-- 3. INDEX rollback — drop ONLY because this sprint created it (verified absent pre-sprint).
DROP INDEX IF EXISTS public.idx_orders_reservation_id_status;

-- 4. (Optional) restore total_spend values from the pre-migration data snapshot.
--    Only needed if the forward migration ran a backfill and you want the exact prior values back.
--    Safe no-op if the snapshot table is absent.
-- UPDATE public.reservations r
--    SET total_spend = s.total_spend
--   FROM public._g4a_20260731_res_datasnap s
--  WHERE r.id = s.id
--    AND r.total_spend IS DISTINCT FROM s.total_spend;

-- Snapshot tables are retained until certification; drop them with blocker4_50_cleanup.sql.
