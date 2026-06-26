-- Run this script against AgencyAssetDB after deploying infrastructure.
-- Connect as the Microsoft Entra ID admin on the SQL server (SSMS or Azure Data Studio).
-- Replace the user name below if your App Service name differs from agencyasset-api.

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'agencyasset-api')
BEGIN
    CREATE USER [agencyasset-api] FROM EXTERNAL PROVIDER;
END
GO

ALTER ROLE db_datareader ADD MEMBER [agencyasset-api];
ALTER ROLE db_datawriter ADD MEMBER [agencyasset-api];
GO

GRANT EXECUTE ON OBJECT::dbo.GetNonAuditedAssets TO [agencyasset-api];
GRANT EXECUTE ON OBJECT::dbo.ResetAssetsTable TO [agencyasset-api];
GO
