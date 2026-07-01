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
- **Swagger UI** for easy testing (with API key support)
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
All shared Azure resources can run within free tier limits, except Azure Key Vault which carries a small monthly cost (~$0.6-0.63) for the vault itself, plus minor per-operation charges.

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