# Agency Asset Management API

A demonstration project showcasing a full-stack solution using **Azure SQL Database** and a minimal **.NET 8 Web API**. Built to highlight proficiency with Microsoft Azure cloud services, infrastructure as code, and secure backend development.

![.NET](https://img.shields.io/badge/.NET-8.0-blue)
![Azure SQL](https://img.shields.io/badge/Azure%20SQL-Database-blue)
![Bicep](https://img.shields.io/badge/Infrastructure-Bicep-blue)

## Overview

This project simulates an internal **Agency Asset Management System** used to track IT and office equipment. It includes:

- An **Azure SQL Database** with stored procedures for data operations
- A lightweight **.NET 10 REST API** with API key authentication
- Infrastructure deployed using **Bicep** (IaC)
- Compliance tracking for asset audits

The goal of this project is to demonstrate Azure cloud development skills.

## Features

- **CRUD operations** on assets (focused on read + audit updates)
- **Compliance tracking** – automatically flags assets that haven't been audited in 90 days
- **Stored Procedures** for optimized database queries
- **Secure API** protected by API key authentication
- **Swagger UI** for easy testing (with API key support)
- **Serverless-ready** Azure SQL configuration (auto-pause enabled)
- **Infrastructure as Code** using Bicep

## Tech Stack

- **Backend**: .NET 10 Minimal API
- **Database**: Azure SQL Database (Serverless)
- **IaC**: Bicep
- **Authentication**: Custom API Key middleware
- **Deployment**: Azure App Service (Free tier F1)

## Architecture
Azure Resource Group
├── Azure SQL Server + Database (AgencyAssetDB)
├── App Service Plan (F1 Free)
└── Web App (.NET 10 API)


## Live Demo

> **Note**: The database uses the serverless tier and may take 30–60 seconds to wake up on first request.

-- TODO: Create a better way to test and demonstrate the API for people to quickly and easily see it in action. For now, you can use the Swagger UI to test the endpoints.

**[View Live API →](https://agency-asset-api.azurewebsites.net/swagger)** *(replace with your actual URL)*

## API Endpoints

| Method | Endpoint                              | Description                              |
|--------|---------------------------------------|------------------------------------------|
| GET    | `/api/assets`                         | Get all assets with compliance status    |
| GET    | `/api/assets/non-audited`             | Get only non-compliant assets            |
| PUT    | `/api/assets/{id}/audit`              | Update an asset's last audit date        |

All endpoints require the `X-Api-Key` header.

## Database

The database contains one main table: `dbo.Assets`. 

**Key columns**:
- `AssetId` (IDENTITY)
- `SerialNumber` (Unique)
- `AssetName`
- `AssignedDepartment`
- `LastAuditDate`

A stored procedure `ResetAssetsTable` is included for easy testing/demo resets.

## Deploy Your Own Instance

### Prerequisites

- Azure subscription
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) (usually installed with Azure CLI)

### Deployment Steps

```bash
# 1. Create resource group
az group create --name agency-asset-rg --location westus3

# 2. Deploy infrastructure
az deployment group create \
  --resource-group agency-asset-rg \
  --template-file infrastructure/main.bicep \
  --parameters sqlAdminLogin='youradmin' \
               sqlAdminPassword='StrongP@ssw0rd123!' \
               apiKey='your-super-secret-api-key'