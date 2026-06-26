-- Create 'GetNonAuditedAssets' Procedure
-- This script is meant to be used with an Azure SQL Database

DROP PROCEDURE IF EXISTS dbo.GetNonAuditedAssets;

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE dbo.GetNonAuditedAssets
	@MaxDaysSinceLastAudit INT = 90
AS
/*
-- =============================================
-- Description: Returns assets which have not been audited within the past number of days given as an input (no input = 90 days)
-- =============================================
*/
BEGIN
	SET NOCOUNT ON;

	SELECT 
		AssetId, 
		SerialNumber, 
		AssetName, 
		AssignedDepartment, 
		LastAuditDate,
		DATEDIFF(DAY, LastAuditDate, GETUTCDATE()) AS DaysSinceLastAudit,
		CASE
        WHEN LastAuditDate < DATEADD(DAY, -@MaxDaysSinceLastAudit, GETUTCDATE())
            OR LastAuditDate IS NULL
        THEN CAST(0 AS BIT)
        ELSE CAST(1 AS BIT)
    END AS IsCompliant
	FROM dbo.Assets
	WHERE LastAuditDate < DATEADD(DAY, -@MaxDaysSinceLastAudit, GETUTCDATE())
		OR LastAuditDate IS NULL;
END
GO