-- Run this script against AgencyAssetDB after deploying infrastructure.
-- Connect as the Microsoft Entra ID admin on the SQL server (SSMS or Azure Data Studio).
-- Uses placeholder $(WebAppName) so it can be token-replaced by deploy.ps1 if desired.

DECLARE @WebAppName sysname = '$(WebAppName)';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @WebAppName)
BEGIN
    EXEC('CREATE USER [' + @WebAppName + '] FROM EXTERNAL PROVIDER;');
END

-- Add managed identity to database roles
EXEC('ALTER ROLE db_datareader ADD MEMBER [' + @WebAppName + ']');
EXEC('ALTER ROLE db_datawriter ADD MEMBER [' + @WebAppName + ']');

-- Grant execute on stored procedures
EXEC('GRANT EXECUTE ON OBJECT::dbo.GetNonAuditedAssets TO [' + @WebAppName + ']');
EXEC('GRANT EXECUTE ON OBJECT::dbo.ResetAssetsTable TO [' + @WebAppName + ']');
GO
