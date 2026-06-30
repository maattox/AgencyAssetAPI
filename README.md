# Agency Asset Management API

A demonstration project showcasing a full-stack solution using **Azure SQL Database** and a minimal **.NET 8 Web API**. Built to highlight proficiency with Microsoft Azure cloud services, infrastructure as code, and secure backend development.

![.NET](https://img.shields.io/badge/.NET-10.0-blue)
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
- **Authentication**: Custom API Key middleware + Passwordless token injection for database access
- **Deployment**: Azure App Service (Free tier F1)

## Architecture
Azure Resource Group
├── Azure Key Vault (API secrets management)
├── Azure SQL Server + Database (Serverless General Purpose Tier)
├── App Service Plan (F1 Free)
└── Web App (.NET 10 Minimal REST API)

## Azure Resources Tier Note
This project is designed to run on the **Free Tier** of Azure App Service and the **Serverless Tier** of Azure SQL Database. 
Every resource used has a free tier besides the Azure Key Vault which technically isn't free but the cost is negligible (~$0.03/10,000 operations).

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