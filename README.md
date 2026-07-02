# Agency Asset Management API

A .NET 10 REST API integrated with Azure cloud services for managing IT and office equipment. Demonstrates practical use of Azure SQL Database, Azure Storage, passwordless authentication, and infrastructure as code.

![.NET](https://img.shields.io/badge/.NET-10.0-blue)
![Azure SQL](https://img.shields.io/badge/Azure%20SQL-Database-blue)
![Azure Blob Storage](https://img.shields.io/badge/Azure-Blob%20Storage-blue)
![Azure Key Vault](https://img.shields.io/badge/Azure-Key%20Vault-blue)
![App Service](https://img.shields.io/badge/Azure-App%20Service-blue)
![Bicep](https://img.shields.io/badge/Infrastructure-Bicep-blue)
![PowerShell](https://img.shields.io/badge/Scripting-PowerShell-blue)

## Overview

This project simulates an internal **Agency Asset Management System** used to track IT and office equipment. It integrates several Azure services to demonstrate a functional backend system with:

- Data persistence in Azure SQL Database
- Audit history archived to Azure Blob Storage
- Secure credential management via Azure Key Vault
- Passwordless authentication using Managed Identity

## Features

- **CRUD operations** on assets (focused on read + audit updates)
- **Compliance tracking** – automatically flags assets that haven't been audited in 90 days
- **Stored Procedures** for optimized database queries
- **Secure API** protected by API key authentication
- **Audit history storage** – compliance reports archived to Azure Blob Storage
- **Key management** – API keys and secrets managed via Azure Key Vault
- **Passwordless authentication** – Managed Identity for database and storage access
- **Serverless-ready** Azure SQL configuration (auto-pause enabled)
- **Infrastructure as Code** using Bicep

## Tech Stack

- **Backend**: .NET 10 Minimal API
- **Database**: Azure SQL Database (Serverless)
- **Storage**: Azure Blob Storage (audit history and reports)
- **Secrets Management**: Azure Key Vault
- **IaC**: Bicep
- **Authentication**: 
  - Passwordless Managed Identity (database & storage)
  - API key validation middleware
- **Deployment**: Azure App Service (Free tier F1)

## Architecture
**Azure Resource Group**  
├── Azure Key Vault (secrets & API keys)  
├── Azure SQL Server + Database (Serverless General Purpose Tier)  
├── Azure Storage Account (Blob Storage for audit history)  
├── App Service Plan (F1 Free)  
└── Web App (.NET 10 REST API)  

## Azure Resources Tier Note
This project is designed to run on the **Free Tier** of Azure App Service and the **Serverless Tier** of Azure SQL Database. 
All shared Azure resources can run within free tier limits, except Azure Key Vault which carries minor per-operation charges.
To ensure the project remains operational after the end of my Azure free trial, a fallback api key is included in the code, but this of course would not be used in a production environment.

## Live Demo

> **Note**: The database uses the serverless tier and may take 30–60 seconds to wake up on first request.

**[View Live API Demo →](https://agencyasset-api-frhba2hmagfbhteg.westus3-01.azurewebsites.net/demo/index.html)**

## Deploy Your Own Instance

The deployment setup provisions your resources, wires up Managed Identity databases roles, creates tables, and seeds initial data.

### Prerequisites
1. An active Azure subscription.
2. [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`).

### Steps
1. Clone this repository.
2. Review and configure local settings inside `/infrastructure/parameters.json`.
3. Open a PowerShell terminal inside the `/infrastructure/` folder and run the automated provisioning file:
   ```powershell
   ./deploy.ps1

4. Enable the Azure SQL free database offer. This can't be set via Bicep/ARM and must be turned on manually after deployment:
   1. Go to the [Azure Portal](https://portal.azure.com).
   2. Navigate to **Resource Groups** > your resource group > **AgencyAssetDB**.
   3. Go to **Settings** > **Compute + storage**.
   4. Switch on **Free database offer** and save.

   `deploy.ps1` will also print a reminder for this step at the end of the run.

## Automation Scripts

The `/infrastructure/` and `/automation/` folders each contain a PowerShell script that automates a distinct part of the project lifecycle: one-time provisioning and ongoing compliance operations, respectively.

### `infrastructure/deploy.ps1` — Environment Provisioning

Orchestrates the full one-time setup of Azure infrastructure and database state, so a fresh environment can be stood up with a single command.

- Deploys the Bicep template (`main.bicep`), retrying across regions if the free-tier App Service SKU isn't available in the initial target region.
- Automatically detects the caller's public IP and Azure AD identity, and passes them into the deployment so the SQL Server firewall and Azure AD admin are configured correctly.
- Runs `setup.sql` against the newly created database using an Azure AD access token — creating the schema, stored procedures, seed data, and the Managed Identity database user the API relies on for passwordless access.
- Persists key deployment outputs (API URL, Key Vault name, Storage account name) as local environment variables, which `Run-AgencyAudit.ps1` (below) uses to auto-discover its target environment.

```powershell
cd infrastructure
./deploy.ps1
```

### `automation/Run-AgencyAudit.ps1` — Compliance Automation

Simulates a scheduled compliance job: it calls the live API to find non-compliant assets, generates an audit report, performs a sample remediation, and archives the results.

- Authenticates to Azure Key Vault via the caller's Azure CLI session to retrieve the API key.
- Calls `GET /api/assets/non-audited` to pull the current list of overdue assets.
- Exports a timestamped CSV compliance report locally (`audit-log-<timestamp>.csv`).
- As a demo of automated remediation, randomly selects one overdue asset and calls `PUT /api/assets/{id}/audit` to mark it audited.
- Uploads the CSV report to the `audit-history` container in Blob Storage, where it becomes visible in the [demo page's Audit History tab](#live-demo).
- Resolves its target environment automatically — checking explicit parameters, then environment variables set by `deploy.ps1`, then `infrastructure/parameters.json`, before falling back to Azure resource discovery (`Get-AzWebApp` / `az webapp show`) — so it can typically be run with no arguments right after `deploy.ps1` completes.

```powershell
cd automation
./Run-AgencyAudit.ps1
```

> This script was originally going to be an Azure Function that ran on a schedule, but there isn't any free tier for Azure Functions so I opted to make it a PowerShell script that can be run manually or scheduled via Windows Task Scheduler or Azure Automation.