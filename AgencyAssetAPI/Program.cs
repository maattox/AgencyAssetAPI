using AgencyAssetAPI;
using Microsoft.OpenApi;
using Azure.Identity;
using Azure.Storage.Blobs;

// ========================================
// Agency Asset Management API - Minimal API Configuration
// ========================================
// This .NET 10 Minimal API demonstrates secure, cloud-native backend development
// using Managed Identity authentication, API key security, and Azure SQL integration.

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSwaggerGen(options =>
{
    // Configure Swagger/OpenAPI to display the custom X-Api-Key header requirement
    // This enables developers to test the API directly from the Swagger UI
    options.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Name = "X-Api-Key",
        Description = "Enter your API key."
    });

    // Apply the security requirement to all endpoints
    options.AddSecurityRequirement(document => new OpenApiSecurityRequirement
    {
        [new OpenApiSecuritySchemeReference("ApiKey", document)] = []
    });
});

var app = builder.Build();

// Configure Swagger UI only in Development to avoid exposing API documentation in production
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(options =>
    {
        options.SwaggerEndpoint("/swagger/v1/swagger.json", "Agency Asset API v1");
        options.RoutePrefix = "swagger";
    });
}

// Enforce HTTPS and serve static files (demo UI)
app.UseHttpsRedirection();
app.UseStaticFiles();

// Load critical configuration from appsettings and Key Vault references
// These will fail fast if not configured, preventing runtime surprises
var expectedApiKey = builder.Configuration.GetValue<string>("Authorization:ApiKey")
    ?? throw new InvalidOperationException("API key not configured.");

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found.");

// Compliance threshold: assets not audited within this period are flagged as non-compliant (default: 90 days)
var maxDaysSinceLastAudit = builder.Configuration.GetValue<int>("SpecialValues:MaxDaysSinceLastAudit", 90);

var storageAccountName = builder.Configuration.GetValue<string>("SpecialValues:StorageAccountName")
    ?? "myagencyassetstore";

// ========================================
// API Key Authentication Middleware
// ========================================
// Custom middleware that validates X-Api-Key header on all protected endpoints.
// Uses StringComparison.Ordinal for constant-time comparison (prevents timing attacks).
// Public endpoints (/swagger, /demo, /health) bypass authentication for usability.
app.Use(async (context, next) =>
{
    var path = context.Request.Path;

    // Whitelist public/unprotected endpoints
    if (path.StartsWithSegments("/swagger") ||
        path.StartsWithSegments("/demo") ||
        path.StartsWithSegments("/api/demo") ||
        path.StartsWithSegments("/api/automation/history") ||
        path.StartsWithSegments("/health"))
    {
        await next(context);
        return;
    }

    // Enforce API key presence
    if (!context.Request.Headers.TryGetValue("X-Api-Key", out var providedKey))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsync("Missing API key.");
        return;
    }

    // Validate API key with constant-time comparison (Ordinal)
    // This prevents attackers from using response timing to infer key characters
    if (!string.Equals(providedKey, expectedApiKey, StringComparison.Ordinal))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsync("Invalid API key.");
        return;
    }

    await next(context);
});

// Default routes
app.MapGet("/", () => Results.Redirect("/demo"));
app.MapGet("/demo", () => Results.Redirect("/demo/index.html"));

// Health check endpoint for infrastructure monitoring
// Returns 503 Service Unavailable if database is unreachable (important for load balancer health probes)
app.MapGet("/health", async (CancellationToken cancellationToken) =>
{
    try
    {
        await AssetDataAccess.CanConnectAsync(connectionString, cancellationToken);
        return Results.Ok(new { status = "healthy", database = "connected" });
    }
    catch (Exception ex)
    {
        return Results.Json(
            new { status = "degraded", database = "unavailable", error = ex.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
})
.WithName("HealthCheck");

// Automation layer integration: retrieve audit history logs from Azure Blob Storage
// Used by Run-AgencyAudit.ps1 to archive compliance reports
app.MapGet("/api/automation/history", async (CancellationToken cancellationToken) =>
{
    var historyFiles = await AssetDataAccess.GetAuditHistoryAsync(storageAccountName, cancellationToken);
    return Results.Ok(historyFiles);
})
.WithName("GetAuditHistory");

// Serves the raw contents of a single audit CSV — used for the demo page's
// expandable preview and for the per-row Download button.
app.MapGet("/api/automation/history/{fileName}", async (string fileName, CancellationToken cancellationToken) =>
{
    var content = await AssetDataAccess.GetAuditFileContentAsync(storageAccountName, fileName, cancellationToken);
    if (content is null)
        return Results.NotFound(new { error = $"File '{fileName}' not found." });

    return Results.Text(content, "text/csv", System.Text.Encoding.UTF8);
})
.WithName("GetAuditFileContent");

// Map asset management routes (protected and demo variants)
MapAssetRoutes("/api/assets", requireApiKey: true);
MapAssetRoutes("/api/demo", requireApiKey: false);

app.Run();

// ========================================
// Asset Management Route Definitions
// ========================================
// Defines GET/PUT endpoints for asset inventory and compliance management.
// Each route is duplicated: one protected (/api/assets) requires API key,
// one demo (/api/demo) is public for testing without credentials.
void MapAssetRoutes(string routePrefix, bool requireApiKey)
{
    // GET non-audited assets: returns assets not audited within maxDays threshold
    // Useful for compliance dashboards and orchestration scripts
    app.MapGet($"{routePrefix}/non-audited", async (int? maxDays, CancellationToken cancellationToken) =>
    {
        var days = maxDays ?? maxDaysSinceLastAudit;
        var assets = await AssetDataAccess.GetNonAuditedAssetsAsync(connectionString, days, cancellationToken);
        return Results.Ok(assets);
    })
    .WithName(requireApiKey ? "GetNonAuditedAssets" : "DemoGetNonAuditedAssets");

    // GET all assets: returns complete inventory with compliance status
    app.MapGet($"{routePrefix}", async (int? maxDays, CancellationToken cancellationToken) =>
    {
        var days = maxDays ?? maxDaysSinceLastAudit;
        var assets = await AssetDataAccess.GetAllAssetsAsync(connectionString, days, cancellationToken);
        return Results.Ok(assets);
    })
    .WithName(requireApiKey ? "GetAssets" : "DemoGetAssets");

    // PUT audit date: updates LastAuditDate for an asset (compliance update)
    // Includes validation: no future dates, no regression of audit dates
    app.MapPut($"{routePrefix}/{{id:int}}/audit", async (int id, DateTime? auditDate, CancellationToken cancellationToken) =>
    {
        var result = await AssetDataAccess.UpdateAuditDateAsync(connectionString, id, auditDate, cancellationToken);
        return result.ToResult();
    })
    .WithName(requireApiKey ? "UpdateAssetAuditDate" : "DemoUpdateAssetAuditDate");

    // POST reset (demo only): restores demo data to original seed state
    // Allows users to test the API without worrying about data persistence
    if (!requireApiKey)
    {
        app.MapPost($"{routePrefix}/reset", async (CancellationToken cancellationToken) =>
        {
            await AssetDataAccess.ResetAssetsTableAsync(connectionString, cancellationToken);
            return Results.Ok(new { message = "Demo data reset to original seed values." });
        })
        .WithName("DemoResetAssets");
    }
}
