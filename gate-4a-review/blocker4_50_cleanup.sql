-- =====================================================================================
-- Gate 4A · Blocker 4 · SNAPSHOT CLEANUP — run ONLY after the migration is certified in staging.
-- Removes the pre-migration snapshot artifacts created by blocker4_00_snapshots.sql.
-- =====================================================================================
DROP TABLE IF EXISTS public._g4a_20260731_objsnap;
DROP TABLE IF EXISTS public._g4a_20260731_res_datasnap;
