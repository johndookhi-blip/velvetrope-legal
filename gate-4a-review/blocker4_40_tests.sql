-- =====================================================================================
-- Gate 4A · Blocker 4 · TEST SUITE  (run AFTER blocker4_10_forward.sql, on STAGING only)
-- Every scenario runs inside BEGIN; ... ROLLBACK; so NO staging data is mutated.
-- Fixtures use the authorized mock venue 81bcd151-e2a2-4c83-956f-77d8756e5b18.
--
-- Schema facts these tests rely on (verified on staging 2026-07-31):
--   * orders.status CHECK = ('open','closed')  -> there is NO 'voided'/'canceled' order status.
--     "canceled order" / "voided order" are therefore modeled as row DELETE (see T13/T14).
--   * A closed order INSERTed directly bypasses guard_orders_no_close_when_unsettled (BEFORE UPDATE
--     only) and recompute_order_financials (returns early on closed) -> amounts are preserved.
--   * total_spend contract per closed order = subtotal+tax+gratuity+service_charge-discount-comp
--     (floored at 0). Deposits, payments, and financial_reversals are EXCLUDED by contract.
--   * refunds / chargebacks tables do NOT exist; those are financial_reversals rows (T17/T18/T19)
--     which by contract never move total_spend.
-- Helper: pass = RAISE NOTICE 'PASS ...'; ASSERT raises assert_failure on mismatch.
-- =====================================================================================

------------------------------------------------------------------------------- T1: no orders
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T1','confirmed') RETURNING id INTO v_res;
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;   -- default 0, no writeback fired
  ASSERT v_ts = 0, format('T1 expected 0 got %s', v_ts);
  RAISE NOTICE 'PASS T1 no orders -> total_spend=0';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T2: one OPEN order (excluded)
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T2','confirmed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, tax_amount)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'open', 100, 8);
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 0, format('T2 expected 0 got %s', v_ts);
  RAISE NOTICE 'PASS T2 open order excluded -> total_spend=0';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T3: one CLOSED order
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric; v_pta numeric; v_pbs text;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T3','confirmed') RETURNING id INTO v_res;
  -- charge = 100 + 8(tax) + 20(grat) + 5(svc) = 133
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, tax_amount, gratuity_amount,
                     service_charge_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 8, 20, 5, 133);
  SELECT total_spend, pos_total_amount, pos_bill_status INTO v_ts, v_pta, v_pbs
  FROM reservations WHERE id = v_res;
  ASSERT v_ts = 133, format('T3 total_spend expected 133 got %s', v_ts);
  -- pos_total_amount stamp is a first-CLOSE-TRANSITION (UPDATE) behavior; a direct closed INSERT
  -- is not a transition, so pos_total_amount stays NULL. (Legacy behavior preserved.)
  ASSERT v_pta IS NULL, format('T3 pos_total_amount expected NULL got %s', v_pta);
  RAISE NOTICE 'PASS T3 closed order -> total_spend=133';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T4: second CLOSED order (aggregate)
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T4','confirmed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100);   -- +100
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, tax_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 50, 4, 54);    -- +54
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 154, format('T4 expected 154 got %s', v_ts);
  RAISE NOTICE 'PASS T4 two closed orders -> total_spend=154';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T5: post-close TOTAL EDIT (manager adjustment on a closed order)
BEGIN;
DO $$
DECLARE v_res uuid; v_oid uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T5','confirmed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 200, 200) RETURNING id INTO v_oid;
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 200, format('T5a expected 200 got %s', v_ts);
  -- Manager edits a charge component on the already-closed order (e.g. adds a $15 service charge).
  UPDATE orders SET service_charge_amount = 15 WHERE id = v_oid;
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 215, format('T5b expected 215 got %s', v_ts);
  RAISE NOTICE 'PASS T5 post-close total edit -> total_spend 200 -> 215';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T6: DISCOUNT reduces charge
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T6','confirmed') RETURNING id INTO v_res;
  -- 100 subtotal - 30 discount = 70
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, discount_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 30, 70);
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 70, format('T6 expected 70 got %s', v_ts);
  RAISE NOTICE 'PASS T6 discount -> total_spend=70';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T7: COMP reduces charge
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T7','confirmed') RETURNING id INTO v_res;
  -- 100 subtotal - 100 comp = 0
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, comp_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100, 0);
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 0, format('T7 expected 0 got %s', v_ts);
  RAISE NOTICE 'PASS T7 fully comped -> total_spend=0';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T8+T9: GRATUITY + SERVICE CHARGE included
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T8','confirmed') RETURNING id INTO v_res;
  -- 100 + 18 grat + 12 svc = 130
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, gratuity_amount, service_charge_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 18, 12, 130);
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 130, format('T8/T9 expected 130 got %s', v_ts);
  RAISE NOTICE 'PASS T8/T9 gratuity+service charge included -> total_spend=130';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T10/T11/T12: DEPOSIT + PARTIAL + FULL PAYMENT excluded
-- Deposits (deposit_applied) and payments (total_paid) are settlement, not charges. They must
-- NOT change total_spend. deposit_applied lowers total_due but is added back into the charge.
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status, deposit_paid, deposit_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T10','confirmed', 50, 'paid') RETURNING id INTO v_res;
  -- charge 100; $50 deposit applied + $50 cash. total_spend must still be 100.
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, deposit_applied, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 50, 50);
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 100, format('T10-12 expected 100 got %s', v_ts);
  RAISE NOTICE 'PASS T10/T11/T12 deposit+partial+full payment excluded -> total_spend=100';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T13/T14: "canceled"/"voided" order  ==  DELETE (no such order.status exists)
BEGIN;
DO $$
DECLARE v_res uuid; v_o1 uuid; v_o2 uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T13','confirmed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100) RETURNING id INTO v_o1;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 40, 40) RETURNING id INTO v_o2;
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 140, format('T13a expected 140 got %s', v_ts);
  DELETE FROM orders WHERE id = v_o2;                 -- void/cancel == remove the order row
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 100, format('T13b expected 100 got %s', v_ts);
  RAISE NOTICE 'PASS T13/T14 delete closed order -> total_spend 140 -> 100';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T15: DELETE the LAST closed order -> total_spend = 0
BEGIN;
DO $$
DECLARE v_res uuid; v_o1 uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T15','confirmed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100) RETURNING id INTO v_o1;
  DELETE FROM orders WHERE id = v_o1;
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 0, format('T15 expected 0 got %s', v_ts);
  RAISE NOTICE 'PASS T15 delete last closed order -> total_spend=0 (no eligible orders remain)';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T16: REASSIGNMENT is guard-blocked (A->B), first-link (NULL->B) recomputes
BEGIN;
DO $$
DECLARE v_a uuid; v_b uuid; v_o uuid; v_ts_b numeric; v_blocked boolean := false;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T16 A','confirmed') RETURNING id INTO v_a;
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T16 B','confirmed') RETURNING id INTO v_b;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_a, 'closed', 100, 100) RETURNING id INTO v_o;
  -- Attempt A->B reassignment: guard_orders_no_reservation_reassignment_fn must RAISE.
  BEGIN
    UPDATE orders SET reservation_id = v_b WHERE id = v_o;
  EXCEPTION WHEN check_violation THEN
    v_blocked := true;
  END;
  ASSERT v_blocked, 'T16 expected reassignment to be guard-blocked';
  RAISE NOTICE 'PASS T16 A->B reassignment blocked by guard (writeback two-row lock is defensive only)';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T17/T18/T19: PAYMENT REFUND / CHARGEBACK / MANAGER ADJUSTMENT do not move total_spend
-- financial_reversals rows (refunds/chargebacks tables do not exist). Constraint domain (verified):
--   reversal_type IN ('commission_reversed','settlement_reversed','refund_processed','adjustment_created')
--   reason        IN ('reservation_cancelled','reservation_refunded','deposit_refunded','chargeback',
--                     'pos_void','pos_refund','manual_adjustment','settlement_reversal','administrative_correction')
--   CHECK financial_reversals_has_origin: original_commission_event_id OR original_settlement_id must be set.
--   UNIQUE financial_reversals_one_per_commission_type: one reversal per (commission_event, reversal_type).
--   UNIQUE commission_events_one_earned_per_reservation: one 'commission_earned' per reservation.
-- A chargeback shares reversal_type='refund_processed' with a pos_refund, so both cannot attach to the
-- same commission event; the payment-refund row below stands in for that class. Manager adjustment uses
-- the distinct 'adjustment_created' type. By contract, none of these change total_spend.
BEGIN;
DO $$
DECLARE v_res uuid; v_c uuid; v_before numeric; v_mid numeric; v_after numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T17','completed') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100);
  SELECT total_spend INTO v_before FROM reservations WHERE id = v_res;
  INSERT INTO commission_events(venue_id, reservation_id, event_type, amount, status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'commission_earned', 15, 'active') RETURNING id INTO v_c;
  -- payment refund / chargeback class (reversal_type refund_processed)
  INSERT INTO financial_reversals(venue_id, reservation_id, original_commission_event_id, reversal_type, reason, amount, source_type, actor)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, v_c, 'refund_processed', 'pos_refund', 40, 'reservation', 'system');
  SELECT total_spend INTO v_mid FROM reservations WHERE id = v_res;
  -- manager adjustment (reversal_type adjustment_created)
  INSERT INTO financial_reversals(venue_id, reservation_id, original_commission_event_id, reversal_type, reason, amount, source_type, actor)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, v_c, 'adjustment_created', 'manual_adjustment', 10, 'reservation', 'manager');
  SELECT total_spend INTO v_after FROM reservations WHERE id = v_res;
  ASSERT v_before = 100 AND v_mid = 100 AND v_after = 100,
    format('T17-19 expected 100/100/100 got %s/%s/%s', v_before, v_mid, v_after);
  RAISE NOTICE 'PASS T17/T18/T19 refund/chargeback/manager-adjustment excluded -> total_spend unchanged=100';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T20: MULTI-ORDER reservation, mixed open/closed
BEGIN;
DO $$
DECLARE v_res uuid; v_ts numeric;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T20','seated') RETURNING id INTO v_res;
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 100, 100);   -- +100
  INSERT INTO orders(venue_id, reservation_id, status, subtotal, tax_amount, total_paid)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'closed', 200, 16, 216); -- +216
  INSERT INTO orders(venue_id, reservation_id, status, subtotal)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'open', 999);             -- excluded
  SELECT total_spend INTO v_ts FROM reservations WHERE id = v_res;
  ASSERT v_ts = 316, format('T20 expected 316 got %s', v_ts);
  RAISE NOTICE 'PASS T20 multi-order (2 closed + 1 open) -> total_spend=316';
END $$;
ROLLBACK;

------------------------------------------------------------------------------- T21: open->close TRANSITION path (exercises unsettled guard + pos_total_amount first-close stamp)
BEGIN;
DO $$
DECLARE v_res uuid; v_oid uuid; v_ts numeric; v_pta numeric; v_pbs text;
BEGIN
  INSERT INTO reservations(venue_id, guest_name, reservation_status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T21','confirmed') RETURNING id INTO v_res;
  -- Insert OPEN (recompute-on-insert zeroes subtotal: no order_items) then set explicit amounts + close.
  INSERT INTO orders(venue_id, reservation_id, status)
  VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', v_res, 'open') RETURNING id INTO v_oid;
  -- charge 120 fully settled by payment so the unsettled-close guard passes.
  UPDATE orders SET subtotal = 120, total_paid = 120, status = 'closed' WHERE id = v_oid;
  SELECT total_spend, pos_total_amount, pos_bill_status INTO v_ts, v_pta, v_pbs
  FROM reservations WHERE id = v_res;
  ASSERT v_ts = 120,  format('T21 total_spend expected 120 got %s', v_ts);
  ASSERT v_pta = 120, format('T21 pos_total_amount expected 120 got %s', v_pta);
  ASSERT v_pbs = 'closed', format('T21 pos_bill_status expected closed got %s', v_pbs);
  RAISE NOTICE 'PASS T21 open->close transition -> total_spend=120, pos_total_amount stamped=120';
END $$;
ROLLBACK;

-- =====================================================================================
-- T22: CONCURRENCY — two SEPARATE transactions each close one order for the SAME reservation.
-- Cannot be simulated in one autocommit session; run in TWO psql sessions as below.
-- The FOR UPDATE lock on the parent reservation serializes the two writebacks: whichever
-- commits second re-aggregates over BOTH now-closed orders. Final total_spend = sum of both.
--
--   -- one-time setup (session 0), note the ids it prints:
--   INSERT INTO reservations(venue_id,guest_name,reservation_status)
--     VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18','G4A T22','seated') RETURNING id;      -- :RES
--   INSERT INTO orders(venue_id,reservation_id,status,subtotal,total_paid)
--     VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', :RES,'open',100,0) RETURNING id;      -- :O1
--   INSERT INTO orders(venue_id,reservation_id,status,subtotal,total_paid)
--     VALUES ('81bcd151-e2a2-4c83-956f-77d8756e5b18', :RES,'open',150,0) RETURNING id;      -- :O2
--
--   -- session A:                              -- session B (start after A's UPDATE, before A commits):
--   BEGIN;                                     BEGIN;
--   UPDATE orders SET total_paid=100,          UPDATE orders SET total_paid=150,
--     status='closed' WHERE id=:O1;              status='closed' WHERE id=:O2;   -- BLOCKS on parent lock
--   COMMIT;                                    -- unblocks, re-aggregates over O1+O2
--                                              COMMIT;
--
--   -- verify (session 0):
--   SELECT total_spend FROM reservations WHERE id=:RES;   -- EXPECT 250 (100+150), never 100 or 150
--   -- cleanup:
--   DELETE FROM orders WHERE reservation_id=:RES; DELETE FROM reservations WHERE id=:RES;
-- =====================================================================================
