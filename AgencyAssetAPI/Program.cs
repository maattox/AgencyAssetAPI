using Microsoft.Data.SqlClient;
using Microsoft.OpenApi;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
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

// Configure the HTTP request pipeline.
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

// Read ApiKey from configuration
// Replace ApiKey with Azure Key Vault later
var expectedApiKey = builder.Configuration.GetValue<string>("Authorization:ApiKey")
    ?? throw new InvalidOperationException("API key not configured.");

// ======================================
// API Key middleware
// ======================================
app.Use(async (context, next) =>
{
    // Let Swagger through without a key
    if (context.Request.Path.StartsWithSegments("/swagger"))
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

// Connect to SQL Server
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found.");

var maxDaysSinceLastAudit = builder.Configuration.GetValue<int>("SpecialValues:MaxDaysSinceLastAudit", 90);

// Compliance check function
static bool CheckCompliance(DateTime? lastAuditDate, int maxDays)
{
    if (!lastAuditDate.HasValue)
        return false;

    var daysSinceLastAudit = (DateTime.UtcNow - lastAuditDate.Value).TotalDays;
    return daysSinceLastAudit <= maxDays;
}

// ======================================
// Map endpoint for GetNonAuditedAssets
// ======================================
app.MapGet("/api/assets/non-audited", async (int? maxDays) =>
{
    var days = maxDays ?? maxDaysSinceLastAudit;

    var assets = new List<Asset>();

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    await using var command = new SqlCommand("GetNonAuditedAssets", connection)
    {
        CommandType = System.Data.CommandType.StoredProcedure
    };

    command.Parameters.AddWithValue("@MaxDaysSinceLastAudit", days);
    await using var reader = await command.ExecuteReaderAsync();

    while (await reader.ReadAsync())
    {
        var lastAuditDate = reader.IsDBNull(4) ? (DateTime?)null : reader.GetDateTime(4);

        assets.Add(new Asset(
            AssetId: reader.GetInt32(0),
            SerialNumber: reader.GetString(1),
            AssetName: reader.IsDBNull(2) ? null : reader.GetString(2),
            AssignedDepartment: reader.IsDBNull(3) ? null : reader.GetString(3),
            LastAuditDate: lastAuditDate,
            IsCompliant: CheckCompliance(lastAuditDate, days)
        ));
    }

    return Results.Ok(assets);
})
.WithName("GetNonAuditedAssets");

// ======================================
// Map endpoint for Querying the entire Assets table
// ======================================
app.MapGet("/api/assets", async (int? maxDays) =>
{
    var days = maxDays ?? maxDaysSinceLastAudit;
    var assets = new List<Asset>();

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    await using var command = new SqlCommand("SELECT * FROM Assets", connection);

    command.Parameters.AddWithValue("@MaxDaysSinceLastAudit", days);
    await using var reader = await command.ExecuteReaderAsync();

    while (await reader.ReadAsync())
    {
        var lastAuditDate = reader.IsDBNull(4) ? (DateTime?)null : reader.GetDateTime(4);

        var ordAssetId = reader.GetOrdinal("AssetId");
        var ordSerial = reader.GetOrdinal("SerialNumber");
        var ordName = reader.GetOrdinal("AssetName");
        var ordDept = reader.GetOrdinal("AssignedDepartment");

        assets.Add(new Asset(
            AssetId: reader.GetInt32(ordAssetId),
            SerialNumber: reader.GetString(ordSerial),
            AssetName: reader.IsDBNull(ordName) ? null : reader.GetString(ordName),
            AssignedDepartment: reader.IsDBNull(ordDept) ? null : reader.GetString(ordDept),
            LastAuditDate: lastAuditDate,
            IsCompliant: CheckCompliance(lastAuditDate, days)
        ));
    }

    return Results.Ok(assets);
})
.WithName("GetAssets");

// ======================================
// Endpoint for updating an asset's audit date
// ======================================
app.MapPut("/api/assets/{id}/audit", async (int id, DateTime? auditDate) =>
{
    if (auditDate.HasValue && auditDate.Value > DateTime.UtcNow)
        return Results.BadRequest("Audit date cannot be in the future.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    // Make sure the asset exists and get its current audit date
    await using var selectCommand = new SqlCommand("SELECT LastAuditDate FROM Assets WHERE AssetId = @Id", connection);
    selectCommand.Parameters.AddWithValue("@Id", id);

    var result = await selectCommand.ExecuteScalarAsync();

    if (result is null)
        return Results.NotFound($"No asset found with ID {id}.");

    // If a date was given, make sure it isn't earlier than the existing one
    if (auditDate.HasValue && result is not DBNull)
    {
        var currentAuditDate = (DateTime)result;
        if (auditDate.Value < currentAuditDate)
            return Results.BadRequest($"Audit date cannot be earlier than the current audit date ({currentAuditDate:yyyy-MM-dd}).");
    }

    var auditDateToSet = auditDate ?? DateTime.UtcNow;

    await using var command = new SqlCommand("UPDATE Assets SET LastAuditDate = @AuditDate WHERE AssetId = @Id", connection);
    command.Parameters.AddWithValue("@AuditDate", auditDateToSet);
    command.Parameters.AddWithValue("@Id", id);

    var updateCommand = await command.ExecuteNonQueryAsync();

    return Results.Ok($"Asset {id} audit date updated to {auditDateToSet:yyyy-MM-dd}.");
})
.WithName("UpdateAssetAuditDate");

app.Run();

// Define response record
internal record Asset(
    int AssetId,
    string SerialNumber,
    string? AssetName,
    string? AssignedDepartment,
    DateTime? LastAuditDate,
    bool IsCompliant
);

