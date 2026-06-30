-- ========================================
-- Agency Asset Database Schema
-- ========================================
-- Creates the primary Assets table for inventory tracking.
-- Designed for Azure SQL Database.
-- Note: Seed data includes varied audit dates to demonstrate compliance logic.

-- Drop existing table if present (safe for redeployment)
IF OBJECT_ID('dbo.Assets', 'U') IS NOT NULL
	DROP TABLE [dbo].[Assets]
GO

-- Assets Inventory Table
-- Columns:
--   AssetId: Surrogate key, auto-increment (IDENTITY)
--   SerialNumber: Unique hardware identifier (enables duplicate prevention)
--   AssetName: Human-readable asset description (e.g., "Dell Latitude 7430 Laptop")
--   AssignedDepartment: Organizational unit responsible for asset
--   LastAuditDate: Most recent compliance audit timestamp (nullable; NULL = never audited)
CREATE TABLE dbo.Assets (
	[AssetId] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
	[SerialNumber] VARCHAR(50) UNIQUE NOT NULL,
	[AssetName] VARCHAR(100) NULL,
	[AssignedDepartment] VARCHAR(50) NULL,
	[LastAuditDate] DATETIME NULL
);
GO

-- ========================================
-- Seed Data (20 Sample Assets)
-- ========================================
-- Populated with varied audit dates to demonstrate:
-- - Compliant assets: audited within 90 days
-- - Non-compliant assets: last audited >90 days ago
-- - Never-audited assets: NULL LastAuditDate (always non-compliant)

INSERT INTO dbo.Assets (
	SerialNumber, 
	AssetName, 
	AssignedDepartment, 
	LastAuditDate
)
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
GO

-- ========================================
-- Verification Query
-- ========================================
-- Returns all assets with calculated compliance status for spot-checking.
-- IsCompliant = 1 if audited within 90 days, 0 otherwise or if never audited.
SELECT 
	AssetId,
	SerialNumber,
	AssetName,
	AssignedDepartment,
	LastAuditDate,
	DATEDIFF(DAY, LastAuditDate, GETUTCDATE()) AS DaysSinceLastAudit,
	CASE
		WHEN LastAuditDate < DATEADD(DAY, -90, GETUTCDATE())
			OR LastAuditDate IS NULL
		THEN CAST(0 AS BIT)
		ELSE CAST(1 AS BIT)
	END AS IsCompliant
FROM dbo.Assets
ORDER BY AssetId;
GO