using AgencyAssetAPI;
using Microsoft.OpenApi;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSwaggerGen(options =>
{
    options.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Name = "X-Api-Key",
        Description = "Enter your API key."
    });

    options.AddSecurityRequirement(document => new OpenApiSecurityRequirement
    {
        [new OpenApiSecuritySchemeReference("ApiKey", document)] = []
    });
});

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(options =>
    {
        options.SwaggerEndpoint("/swagger/v1/swagger.json", "Agency Asset API v1");
        options.RoutePrefix = "swagger";
    });
}

app.UseHttpsRedirection();
app.UseStaticFiles();

var expectedApiKey = builder.Configuration.GetValue<string>("Authorization:ApiKey")
    ?? throw new InvalidOperationException("API key not configured.");

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found.");

var maxDaysSinceLastAudit = builder.Configuration.GetValue<int>("SpecialValues:MaxDaysSinceLastAudit", 90);

app.Use(async (context, next) =>
{
    var path = context.Request.Path;

    if (path.StartsWithSegments("/swagger") ||
        path.StartsWithSegments("/demo") ||
        path.StartsWithSegments("/api/demo") ||
        path.StartsWithSegments("/health"))
    {
        await next(context);
        return;
    }

    if (!context.Request.Headers.TryGetValue("X-Api-Key", out var providedKey))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsync("Missing API key.");
        return;
    }

    if (!string.Equals(providedKey, expectedApiKey, StringComparison.Ordinal))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsync("Invalid API key.");
        return;
    }

    await next(context);
});

app.MapGet("/", () => Results.Redirect("/demo"));
app.MapGet("/demo", () => Results.Redirect("/demo/index.html"));

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

MapAssetRoutes("/api/assets", requireApiKey: true);
MapAssetRoutes("/api/demo", requireApiKey: false);

app.Run();

void MapAssetRoutes(string routePrefix, bool requireApiKey)
{
    app.MapGet($"{routePrefix}/non-audited", async (int? maxDays, CancellationToken cancellationToken) =>
    {
        var days = maxDays ?? maxDaysSinceLastAudit;
        var assets = await AssetDataAccess.GetNonAuditedAssetsAsync(connectionString, days, cancellationToken);
        return Results.Ok(assets);
    })
    .WithName(requireApiKey ? "GetNonAuditedAssets" : "DemoGetNonAuditedAssets");

    app.MapGet($"{routePrefix}", async (int? maxDays, CancellationToken cancellationToken) =>
    {
        var days = maxDays ?? maxDaysSinceLastAudit;
        var assets = await AssetDataAccess.GetAllAssetsAsync(connectionString, days, cancellationToken);
        return Results.Ok(assets);
    })
    .WithName(requireApiKey ? "GetAssets" : "DemoGetAssets");

    app.MapPut($"{routePrefix}/{{id:int}}/audit", async (int id, DateTime? auditDate, CancellationToken cancellationToken) =>
    {
        var result = await AssetDataAccess.UpdateAuditDateAsync(connectionString, id, auditDate, cancellationToken);
        return result.ToResult();
    })
    .WithName(requireApiKey ? "UpdateAssetAuditDate" : "DemoUpdateAssetAuditDate");

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
