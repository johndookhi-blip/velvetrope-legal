-- =====================================================================================
-- Gate 4B · ROLLBACK — restores the exact pre-sprint deployed state. STAGING only.
-- =====================================================================================

-- 1. Restore trigger to pre-sprint wiring (AFTER UPDATE only).
DROP TRIGGER IF EXISTS trg_pos_writeback ON public.orders;
CREATE TRIGGER trg_pos_writeback
  AFTER UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.pos_writeback_to_reservation();

-- 2. Restore the ORIGINAL writeback function body verbatim (captured from staging 2026-07-31).
CREATE OR REPLACE FUNCTION public.pos_writeback_to_reservation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
         and pos_bill_status is distinct from 'closed';
    end if;
  exception when others then
    raise warning 'pos_writeback_to_reservation failed for order %: %', new.id, sqlerrm;
  end;
  return new;
end;
$function$;

-- 3. Drop the reusable recalculator introduced by this sprint.
DROP FUNCTION IF EXISTS public.recalculate_reservation_total_spend(uuid);

-- 4. Drop the index this sprint created (verified absent pre-sprint).
DROP INDEX IF EXISTS public.idx_orders_reservation_id_status;

-- 5. (Optional) restore prior total_spend values if the forward backfill ran:
-- UPDATE public.reservations r SET total_spend = s.total_spend
--   FROM public._g4b_snap_reservations s
--  WHERE r.id = s.id AND r.total_spend IS DISTINCT FROM s.total_spend;
