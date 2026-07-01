-- =============================================
-- Agency Asset Database - Post-Deployment Setup Script
-- =============================================
-- This consolidated script is used by deploy.ps1 to initialize the database.
-- It handles:
--   A. Schema creation (Assets table)
--   B. Managed Identity configuration (passwordless app access)
--   C. Stored procedures (compliance queries and utilities)
--   D. Seed data (20 sample assets with varied audit dates)
--
-- Parameters:
--   $(WebAppName) — injected by PowerShell to enable dynamic Managed Identity binding

-- =============================================
-- Section A: Create Assets Table (if not exists)
-- =============================================
-- Idempotent check prevents errors if table already exists.
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Assets' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
	CREATE TABLE dbo.Assets (
		AssetId          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
		SerialNumber     VARCHAR(50) UNIQUE NOT NULL,
		AssetName        VARCHAR(100) NULL,
		AssignedDepartment VARCHAR(50) NULL,
		LastAuditDate    DATETIME NULL
	);
	PRINT 'Table [dbo].[Assets] created.';
END
ELSE
	PRINT 'Table [dbo].[Assets] already exists.';

-- =============================================
-- Section B: Managed Identity Configuration
-- =============================================
-- Creates a database user linked to the Web App's Managed Identity.
-- This enables passwordless authentication: the app token is validated by Azure AD.
-- 
-- RBAC roles:
--   db_datareader: read access (SELECT)
--   db_datawriter: write access (INSERT, UPDATE)
-- 
-- The @WebAppName variable is dynamically replaced by deploy.ps1 during execution.
DECLARE @WebAppName sysname = '$(WebAppName)';

IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = @WebAppName)
BEGIN
	EXEC('CREATE USER [' + @WebAppName + '] FROM EXTERNAL PROVIDER;');
	EXEC('ALTER ROLE db_datareader ADD MEMBER [' + @WebAppName + '];');
	EXEC('ALTER ROLE db_datawriter ADD MEMBER [' + @WebAppName + '];');
	PRINT 'Managed Identity access granted for: ' + @WebAppName;
END
ELSE
	PRINT 'Managed Identity already exists: ' + @WebAppName;

-- =============================================
-- Section C: Stored Procedures
-- =============================================
-- GetNonAuditedAssets: Returns assets violating compliance threshold
IF OBJECT_ID('dbo.GetNonAuditedAssets', 'P') IS NOT NULL
	DROP PROCEDURE dbo.GetNonAuditedAssets;
GO

CREATE PROCEDURE dbo.GetNonAuditedAssets
	@MaxDaysSinceLastAudit INT = 90
AS
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
			WHEN LastAuditDate < DATEADD(DAY, -@MaxDaysSinceLastAudit, GETUTCDATE()) OR LastAuditDate IS NULL
			THEN CAST(0 AS BIT)
			ELSE CAST(1 AS BIT)
		END AS IsCompliant
	FROM dbo.Assets
	WHERE LastAuditDate < DATEADD(DAY, -@MaxDaysSinceLastAudit, GETUTCDATE())
		OR LastAuditDate IS NULL;
END
GO
PRINT 'Stored Procedure [dbo].[GetNonAuditedAssets] created.';

-- ResetAssetsTable: Restores original seed data (demo purposes)
IF OBJECT_ID('dbo.ResetAssetsTable', 'P') IS NOT NULL
	DROP PROCEDURE dbo.ResetAssetsTable;
GO

CREATE PROCEDURE dbo.ResetAssetsTable
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Assets;

	-- Safely reset IDENTITY counter
	IF EXISTS(SELECT * FROM sys.identity_columns WHERE OBJECT_NAME(object_id) = 'Assets' AND last_value IS NOT NULL)
		DBCC CHECKIDENT ('dbo.Assets', RESEED, 0);

	-- Re-seed with 20 sample assets
	INSERT INTO dbo.Assets (SerialNumber, AssetName, AssignedDepartment, LastAuditDate)
	VALUES
		('SN-LP-1001', 'Dell Latitude 7430 Laptop', 'IT', DATEADD(DAY, -120, GETUTCDATE())),
		('SN-DT-2002', 'HP EliteDesk 800 G8', 'Finance', DATEADD(DAY, -45, GETUTCDATE())),
		('SN-SRV-3003', 'Dell PowerEdge R750 Server', 'Operations', NULL),
		('SN-PRT-4004', 'Canon ImageCLASS MF743CDW Printer', 'HR', DATEADD(DAY, -200, GETUTCDATE())),
		('SN-LP-1005', 'Lenovo ThinkPad X1 Carbon', 'Security', DATEADD(DAY, -30, GETUTCDATE())),
		('SN-MON-5006', 'Samsung 34" Curved Monitor', 'IT', DATEADD(DAY, -95, GETUTCDATE())),
		('SN-PH-6007', 'iPhone 14 Pro (Agency)', 'Executive', DATEADD(DAY, -15, GETUTCDATE())),
		('SN-TAB-7008', 'Microsoft Surface Pro 9', 'Training', DATEADD(DAY, -180, GETUTCDATE())),
		('SN-NTB-1009', 'MacBook Pro 16"', 'Legal', NULL),
		('SN-DSK-2010', 'Dell OptiPlex 7090 Tower', 'Finance', DATEADD(DAY, -60, GETUTCDATE())),
		('SN-PRT-4011', 'HP LaserJet Enterprise', 'Operations', DATEADD(DAY, -250, GETUTCDATE())),
		('SN-LP-1012', 'Dell XPS 15', 'IT', DATEADD(DAY, -10, GETUTCDATE())),
		('SN-SRV-3013', 'HPE ProLiant DL380', 'Data Center', DATEADD(DAY, -400, GETUTCDATE())),
		('SN-MOB-6014', 'Samsung Galaxy Tab S8', 'Field Services', NULL),
		('SN-LP-1015', 'Lenovo Yoga 9i', 'HR', DATEADD(DAY, -75, GETUTCDATE())),
		('SN-PRJ-8016', 'Epson EB-1080 Projector', 'Training', DATEADD(DAY, -110, GETUTCDATE())),
		('SN-DSK-2017', 'HP Z2 Mini Workstation', 'Legal', DATEADD(DAY, -50, GETUTCDATE())),
		('SN-PH-6018', 'Google Pixel 7a (Agency)', 'Security', DATEADD(DAY, -25, GETUTCDATE())),
		('SN-NAS-9019', 'Synology DS1821+ NAS', 'IT', DATEADD(DAY, -300, GETUTCDATE())),
		('SN-LP-1020', 'Acer Aspire 5', 'Operations', DATEADD(DAY, -5, GETUTCDATE()));

	SELECT * FROM dbo.Assets ORDER BY AssetId;
END
GO
PRINT 'Stored Procedure [dbo].[ResetAssetsTable] created.';

-- =============================================
-- Section D: Initialize Database with Seed Data
-- =============================================
-- Calls ResetAssetsTable to populate the database.
EXEC dbo.ResetAssetsTable;

-- =============================================
-- Section E: Grant Execute Permissions to Managed Identity
-- =============================================
-- Ensure the Web App Managed Identity (created earlier as @WebAppName) has EXECUTE permission on the stored procedures
IF OBJECT_ID('dbo.GetNonAuditedAssets', 'P') IS NOT NULL
BEGIN
	EXEC('GRANT EXECUTE ON OBJECT::dbo.GetNonAuditedAssets TO [' + @WebAppName + ']');
END

IF OBJECT_ID('dbo.ResetAssetsTable', 'P') IS NOT NULL
BEGIN
	EXEC('GRANT EXECUTE ON OBJECT::dbo.ResetAssetsTable TO [' + @WebAppName + ']');
END
