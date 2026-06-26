-- Test 'GetNonAuditedAssets' Procedure
-- This script is meant to be used with an Azure SQL Database

DECLARE	@return_value int

EXEC	@return_value = [dbo].[GetNonAuditedAssets] @MaxDaysSinceLastAudit = 90

SELECT	'Return Value' = @return_value

GO