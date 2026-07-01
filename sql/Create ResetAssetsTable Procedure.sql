-- Create 'ResetAssetsTable' Procedure (for testing purposes)
-- This script is meant to be used with an Azure SQL Database

DROP PROCEDURE IF EXISTS dbo.ResetAssetsTable;

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE dbo.ResetAssetsTable
WITH EXECUTE AS OWNER
AS
/*
-- =============================================
-- Description: Resets 'Assets' table to original values
-- =============================================
*/
BEGIN
    SET NOCOUNT ON;

    -- Clear existing data
    TRUNCATE TABLE dbo.Assets;
    
    -- Reset the IDENTITY seed back to 1
    DBCC CHECKIDENT ('dbo.Assets', RESEED, 0);
    
    -- Re-insert original data
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
END
GO