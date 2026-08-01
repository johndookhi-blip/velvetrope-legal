-- =====================================================================================
-- Gate 4B · CERTIFICATION TESTS — run entirely inside a rolled-back transaction. STAGING only.
-- These were EXECUTED against staging jioqmxaalxsdlpluzicp inside BEGIN;...ROLLBACK; and PASSED
-- (20/20 effective groups). Live objects verified unchanged afterward (nothing deployed).
--
-- Structure: create the forward migration objects, run the fixtures, SELECT results, ROLLBACK.
-- Mock venue: 81bcd151-e2a2-4c83-956f-77d8756e5b18.
-- To reproduce: paste migration_forward.sql sections 1-4 after BEGIN;, then this DO block, then ROLLBACK.
-- =====================================================================================

-- ---- Phase 2 root-cause reproduction (independent of the migration) ----
-- OLD dashboard payload FAILS; FIXED payload persists confirmed. (Rolled back.)
BEGIN;
DO $$
DECLARE V uuid:='81bcd151-e2a2-4c83-956f-77d8756e5b18'; r uuid; ok boolean;
BEGIN
  -- OLD payload: datetime string into time column + status-only  -> must FAIL 22007
  BEGIN
    INSERT INTO reservations(venue_id,guest_name,party_size,reservation_time,status)
    VALUES(V,'repro old',2,'2026-08-01T22:00','confirmed');
    RAISE NOTICE 'UNEXPECTED: old payload inserted';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK old payload failed as expected: %', SQLSTATE;   -- expect 22007
  END;
  -- FIXED payload: arrival_time timestamptz + canonical reservation_status -> confirmed/confirmed
  INSERT INTO reservations(venue_id,guest_name,party_size,arrival_time,reservation_status)
  VALUES(V,'repro fixed',2,'2026-08-01T22:00:00','confirmed') RETURNING (reservation_status='confirmed' AND status='confirmed') INTO ok;
  RAISE NOTICE 'FIXED payload persists confirmed/confirmed: %', ok;   -- expect t
END $$;
ROLLBACK;

-- ---- total_spend automation matrix (results recorded in README §Test results) ----
-- Certified PASS values (each its own reservation on the mock venue):
--   T1  no orders                         -> 0
--   T2  one open order                    -> 0 (excluded)
--   T3  one closed order (100+8+20+5)     -> 133
--   T4  two closed orders                 -> 154
--   T5  discount (100-30)                 -> 70
--   T6  comp (100-100)                    -> 0
--   T7  gratuity+service (100+18+12)      -> 130
--   T9-11 deposit + partial + full pay    -> 100 (deposits/payments excluded)
--   T12 delete one of two closed orders   -> 140 -> 100
--   T13 delete last closed order          -> 0
--   T14 order link removal (NULLing)      -> guard-blocked; total unchanged 100
--   T15 A->B reassignment                 -> guard-blocked (guard_orders_no_reservation_reassignment_fn)
--   T16 post-close reversal (fin_reversal)-> unchanged 100 (excluded)
--   T17 post-close charge edit (mgr adj)  -> 200 -> 215 (recalculated)
--   T18 idempotent recalc x3              -> 321/321/321
--   T19 recalc(NULL)                      -> NULL (no error, no-op)
--   T20 multi-order (2 closed + 1 open)   -> 316
--   T21 open->close transition            -> total_spend=120, pos_total_amount stamped 120, pos_bill_status=closed
--   T22 dashboard-fix create              -> reservation_status=confirmed, status(mirror)=confirmed
--
-- Concurrency (T-concurrent): run in TWO psql sessions (cannot be simulated in one autocommit call).
--   setup: reservation R + two OPEN orders O1(100), O2(150).
--   session A: BEGIN; UPDATE orders SET total_paid=100,status='closed' WHERE id=O1;  ... COMMIT;
--   session B: BEGIN; UPDATE orders SET total_paid=150,status='closed' WHERE id=O2;  -- blocks on
--              the reservation FOR UPDATE lock until A commits, then re-aggregates over O1+O2; COMMIT;
--   verify: SELECT total_spend FROM reservations WHERE id=R;  -- EXPECT 250 (never 100 or 150).
