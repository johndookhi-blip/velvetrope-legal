-- =====================================================================================
-- Gate 4A · Blocker 4 · RECONCILIATION (read-only; run AFTER forward migration + optional backfill)
-- Proves total_spend matches an independent recomputation, and that only intended rows changed.
-- =====================================================================================

-- R1. Independent recomputation of the contract, compared to the stored value.
--     Expect ZERO rows. Any row = a reservation whose stored total_spend disagrees with the
--     closed-order aggregate (subtotal+tax+gratuity+service_charge-discount-comp, floored per order).
WITH expected AS (
  SELECT r.id AS reservation_id,
         COALESCE(SUM(GREATEST(
             COALESCE(o.subtotal,0) + COALESCE(o.tax_amount,0) + COALESCE(o.gratuity_amount,0)
           + COALESCE(o.service_charge_amount,0) - COALESCE(o.discount_amount,0) - COALESCE(o.comp_amount,0), 0)
         ), 0) AS expected_total_spend
  FROM public.reservations r
  LEFT JOIN public.orders o
         ON o.reservation_id = r.id AND o.status = 'closed'
  GROUP BY r.id
)
SELECT r.id, r.total_spend AS stored, e.expected_total_spend AS expected,
       (r.total_spend - e.expected_total_spend) AS delta
FROM public.reservations r
JOIN expected e ON e.reservation_id = r.id
WHERE r.total_spend IS DISTINCT FROM e.expected_total_spend
ORDER BY abs(r.total_spend - e.expected_total_spend) DESC;

-- R2. Change surface vs the pre-migration data snapshot: which reservations had total_spend changed,
--     and confirm pos_total_amount / pos_bill_status / pos_closed_at were NOT disturbed by a backfill.
SELECT count(*) FILTER (WHERE r.total_spend      IS DISTINCT FROM s.total_spend)      AS total_spend_changed,
       count(*) FILTER (WHERE r.pos_total_amount IS DISTINCT FROM s.pos_total_amount) AS pos_total_amount_changed,
       count(*) FILTER (WHERE r.pos_bill_status  IS DISTINCT FROM s.pos_bill_status)  AS pos_bill_status_changed,
       count(*) FILTER (WHERE r.pos_closed_at    IS DISTINCT FROM s.pos_closed_at)    AS pos_closed_at_changed
FROM public.reservations r
JOIN public._g4a_20260731_res_datasnap s ON s.id = r.id;
-- Expectation after a pure function/trigger swap (no backfill): all four columns = 0 changed.
-- After an intentional total_spend backfill: total_spend_changed >= 0, the other three = 0.

-- R3. Row-count parity (no reservations/orders created or lost by the migration).
SELECT (SELECT count(*) FROM public.reservations)                    AS reservations_now,
       (SELECT count(*) FROM public._g4a_20260731_res_datasnap)      AS reservations_snapshot;
