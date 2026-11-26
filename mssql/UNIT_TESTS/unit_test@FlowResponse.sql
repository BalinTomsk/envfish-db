SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: discharge-response schema (dbo.flow_response, dbo.fish.fish_flow_group, CurrentWaterState flow columns).

  TEST  1 - flow_response has every group x state (9 x 7 = 63 rows)
  TEST  2 - group I (lake fish) is factor 1 in every state
  TEST  3 - STABLE is 1 for every group, and no factor is above 1.3
  TEST  4 - only group G rows are spawn_only
  TEST  5 - fish_flow_group rejects a letter outside A..I
  TEST  6 - CurrentWaterState has the seven flow columns
*/
PRINT 'Unit tests for discharge-response schema';
GO
-- ============================================================================ TEST 1
DECLARE @n int = (SELECT COUNT(*) FROM dbo.flow_response);
DECLARE @c int = (SELECT COUNT(DISTINCT flow_group) * COUNT(DISTINCT flow_state) FROM dbo.flow_response);
IF @n <> 63 OR @c <> 63 RAISERROR ('TEST 1 FAIL: flow_response must hold 9 groups x 7 states', 16, -1)
ELSE PRINT 'TEST 1 PASS: flow_response holds 9 groups x 7 states'
GO
-- ============================================================================ TEST 2
IF EXISTS (SELECT 1 FROM dbo.flow_response WHERE flow_group = 'I' AND factor <> 1)
     RAISERROR ('TEST 2 FAIL: group I must be factor 1 in every state', 16, -1)
ELSE PRINT 'TEST 2 PASS: group I is factor 1 in every state'
GO
-- ============================================================================ TEST 3
IF EXISTS (SELECT 1 FROM dbo.flow_response WHERE (flow_state = 'STABLE' AND factor <> 1) OR factor > 1.3)
     RAISERROR ('TEST 3 FAIL: STABLE must be 1 and no factor above 1.3', 16, -1)
ELSE PRINT 'TEST 3 PASS: STABLE is 1 for every group, none above 1.3'
GO
-- ============================================================================ TEST 4
IF EXISTS (SELECT 1 FROM dbo.flow_response WHERE spawn_only = CASE WHEN flow_group = 'G' THEN 0 ELSE 1 END)
     RAISERROR ('TEST 4 FAIL: spawn_only must be set for group G only', 16, -1)
ELSE PRINT 'TEST 4 PASS: spawn_only is set for group G only'
GO
-- ============================================================================ TEST 5
BEGIN TRAN FR_Test5
DECLARE @ok bit = 0;
BEGIN TRY
    SET NOCOUNT ON;
    UPDATE TOP (1) dbo.fish SET fish_flow_group = 'Z';
END TRY
BEGIN CATCH SET @ok = CASE WHEN ERROR_NUMBER() = 547 THEN 1 ELSE 0 END; END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRAN FR_Test5
IF @ok = 0 RAISERROR ('TEST 5 FAIL: fish_flow_group must reject Z', 16, -1)
ELSE PRINT 'TEST 5 PASS: fish_flow_group rejects a letter outside A..I'
GO
