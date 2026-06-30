using System.Data;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Data.SqlClient;

namespace AgencyAssetAPI;

// ========================================
// Data Access Layer - Agency Asset Management
// ========================================
// This class demonstrates secure database access using:
// - Managed Identity authentication (passwordless, no credentials in app)
// - ADO.NET with parameterized queries (prevents SQL injection)
// - Async/await throughout for scalability
// - Azure Storage integration for compliance audit trails
internal static class AssetDataAccess
{
    // Lazily-initialized Azure credential: used for both SQL and Blob Storage authentication
    // Reusing the same credential across Azure services follows the principle of least privilege
    private static readonly Lazy<DefaultAzureCredential> _azureCredential =
        new(() => new DefaultAzureCredential());

    /// <summary>
    /// Opens a passwordless SQL connection using Managed Identity token injection.
    /// If the connection string contains UserID/Password, standard authentication is used.
    /// Otherwise, a DefaultAzureCredential token is injected for Managed Identity access.
    /// 
    /// This enables:
    /// - Zero credentials stored in appsettings
    /// - Automatic token refresh via Azure SDK
    /// - RBAC enforcement at the database level
    /// </summary>
    private static async Task<SqlConnection> OpenConnectionAsync(string connectionString, CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(connectionString);
        var builder = new SqlConnectionStringBuilder(connectionString);

        // If no SQL User or Password is provided, use Azure Managed Identity token injection
        if (string.IsNullOrEmpty(builder.UserID) && string.IsNullOrEmpty(builder.Password))
        {
            // Request a token scoped to Azure SQL Database
            var tokenRequestContext = new TokenRequestContext(["https://database.windows.net/.default"]);
            var accessToken = await _azureCredential.Value.GetTokenAsync(tokenRequestContext, cancellationToken);
            connection.AccessToken = accessToken.Token;
        }

        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    /// <summary>
    /// Determines if an asset meets compliance standards.
    /// An asset is compliant if it has been audited within the past maxDays days.
    /// Assets never audited are considered non-compliant.
    /// </summary>
    internal static bool CheckCompliance(DateTime? lastAuditDate, int maxDays)
    {
        if (!lastAuditDate.HasValue)
            return false;

        var daysSinceLastAudit = (DateTime.UtcNow - lastAuditDate.Value).TotalDays;
        return daysSinceLastAudit <= maxDays;
    }

    /// <summary>
    /// Retrieves all assets from the database and evaluates compliance status.
    /// Uses direct SQL query (not a stored procedure) for flexibility in this read operation.
    /// </summary>
    internal static async Task<List<Asset>> GetAllAssetsAsync(string connectionString, int maxDays, CancellationToken cancellationToken = default)
    {
        var assets = new List<Asset>();

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        // Parameterized query: while no user input is here, this demonstrates best practice
        await using var command = new SqlCommand("SELECT AssetId, SerialNumber, AssetName, AssignedDepartment, LastAuditDate FROM Assets", connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            assets.Add(ReadAsset(reader, maxDays));
        }

        return assets;
    }

    /// <summary>
    /// Retrieves assets that violate compliance thresholds using a stored procedure.
    /// The stored procedure performs the filtering at the database engine level for efficiency.
    /// 
    /// Demonstrates:
    /// - Stored procedure usage for complex business logic
    /// - Parameterized query injection (@MaxDaysSinceLastAudit)
    /// - Used by compliance dashboards and the Run-AgencyAudit.ps1 automation script
    /// </summary>
    internal static async Task<List<Asset>> GetNonAuditedAssetsAsync(string connectionString, int maxDays, CancellationToken cancellationToken = default)
    {
        var assets = new List<Asset>();

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        // Call the stored procedure with parameterized input (prevents SQL injection)
        await using var command = new SqlCommand("GetNonAuditedAssets", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        // Parameterized input: @MaxDaysSinceLastAudit is safely bound by SqlClient
        command.Parameters.Add("@MaxDaysSinceLastAudit", SqlDbType.Int).Value = maxDays;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            assets.Add(ReadAsset(reader, maxDays));
        }

        return assets;
    }

    /// <summary>
    /// Updates the audit date for an asset, with business logic validation.
    /// 
    /// Validation rules:
    /// - Audit date cannot be in the future (prevents data corruption)
    /// - Audit date cannot regress (audit history is immutable; only forward updates allowed)
    /// - If no date is provided, defaults to current UTC time
    /// 
    /// Demonstrates:
    /// - Business rule enforcement at the application layer
    /// - Parameterized queries for UPDATE statements
    /// - Proper error handling with structured result objects
    /// </summary>
    internal static async Task<AuditUpdateResult> UpdateAuditDateAsync(string connectionString, int id, DateTime? auditDate, CancellationToken cancellationToken = default)
    {
        // Validate: no future dates allowed
        if (auditDate.HasValue && auditDate.Value > DateTime.UtcNow)
            return AuditUpdateResult.BadRequest("Audit date cannot be in the future.");

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        // Fetch current audit date for validation
        await using var selectCommand = new SqlCommand("SELECT LastAuditDate FROM Assets WHERE AssetId = @Id", connection);
        selectCommand.Parameters.Add("@Id", SqlDbType.Int).Value = id;

        var result = await selectCommand.ExecuteScalarAsync(cancellationToken);

        // Asset not found
        if (result is null)
            return AuditUpdateResult.NotFound(id);

        // Validate: no regression of audit dates (audit trail is immutable)
        if (auditDate.HasValue && result is not DBNull)
        {
            var currentAuditDate = (DateTime)result;
            if (auditDate.Value < currentAuditDate)
            {
                return AuditUpdateResult.BadRequest(
                    $"Audit date cannot be earlier than the current audit date ({currentAuditDate:yyyy-MM-dd}).");
            }
        }

        // Use current UTC time if no date provided
        var auditDateToSet = auditDate ?? DateTime.UtcNow;

        // Execute parameterized UPDATE
        await using var command = new SqlCommand("UPDATE Assets SET LastAuditDate = @AuditDate WHERE AssetId = @Id", connection);
        command.Parameters.Add("@AuditDate", SqlDbType.DateTime).Value = auditDateToSet;
        command.Parameters.Add("@Id", SqlDbType.Int).Value = id;

        await command.ExecuteNonQueryAsync(cancellationToken);

        return AuditUpdateResult.Ok(id, auditDateToSet);
    }

    /// <summary>
    /// Retrieves audit history files from Azure Blob Storage.
    /// Used by the /api/automation/history endpoint to expose compliance logs
    /// generated by the Run-AgencyAudit.ps1 automation script.
    /// 
    /// Demonstrates:
    /// - Azure Storage integration using Managed Identity
    /// - Reusing the same DefaultAzureCredential for multiple Azure services
    /// - Async enumeration over paginated blob results
    /// </summary>
    internal static async Task<List<AuditHistoryFile>> GetAuditHistoryAsync(
        string storageAccountName,
        CancellationToken cancellationToken = default)
    {
        // Construct container URI: https://{storageAccountName}.blob.core.windows.net/audit-history
        var containerUri = new Uri($"https://{storageAccountName}.blob.core.windows.net/audit-history");

        // Reuse the same passwordless credential used for SQL token acquisition
        var blobContainerClient = new BlobContainerClient(containerUri, _azureCredential.Value);

        var historyFiles = new List<AuditHistoryFile>();

        // Enumerate all blobs in the audit-history container
        await foreach (var blobItem in blobContainerClient.GetBlobsAsync(cancellationToken: cancellationToken))
        {
            historyFiles.Add(new AuditHistoryFile(
                FileName: blobItem.Name,
                CreatedOn: blobItem.Properties.CreatedOn,
                SizeInBytes: blobItem.Properties.ContentLength));
        }

        // Return most recent files first
        return historyFiles
            .OrderByDescending(f => f.CreatedOn)
            .ToList();
    }

    /// <summary>
    /// Resets the Assets table to its original seed state (demo purposes).
    /// Calls the ResetAssetsTable stored procedure which truncates and re-seeds with 20 sample assets.
    /// </summary>
    internal static async Task ResetAssetsTableAsync(string connectionString, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        await using var command = new SqlCommand("ResetAssetsTable", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    /// <summary>
    /// Health check: attempts to open a database connection.
    /// Returns true if connection succeeds, throws exception otherwise.
    /// Used by the /health endpoint for infrastructure monitoring.
    /// </summary>
    internal static async Task<bool> CanConnectAsync(string connectionString, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);
        return true;
    }

    /// <summary>
    /// Reads a single Asset from a SqlDataReader using column ordinals.
    /// Uses GetOrdinal() to safely handle column ordering without hard-coding indices.
    /// Handles nullable fields gracefully (e.g., AssetName, AssignedDepartment, LastAuditDate).
    /// </summary>
    private static Asset ReadAsset(SqlDataReader reader, int maxDays)
    {
        // Use GetOrdinal to safely reference columns by name (more resilient than indices)
        var ordAssetId = reader.GetOrdinal("AssetId");
        var ordSerial = reader.GetOrdinal("SerialNumber");
        var ordName = reader.GetOrdinal("AssetName");
        var ordDept = reader.GetOrdinal("AssignedDepartment");
        var ordLastAudit = reader.GetOrdinal("LastAuditDate");

        // Handle nullable LastAuditDate
        var lastAuditDate = reader.IsDBNull(ordLastAudit) ? (DateTime?)null : reader.GetDateTime(ordLastAudit);

        return new Asset(
            AssetId: reader.GetInt32(ordAssetId),
            SerialNumber: reader.GetString(ordSerial),
            AssetName: reader.IsDBNull(ordName) ? null : reader.GetString(ordName),
            AssignedDepartment: reader.IsDBNull(ordDept) ? null : reader.GetString(ordDept),
            LastAuditDate: lastAuditDate,
            IsCompliant: CheckCompliance(lastAuditDate, maxDays)
        );
    }

    /// <summary>
    /// Represents a single asset in the agency inventory.
/// IsCompliant is calculated at query time based on audit date and compliance threshold.
/// </summary>
internal record Asset(
    int AssetId,
    string SerialNumber,
    string? AssetName,
    string? AssignedDepartment,
    DateTime? LastAuditDate,
    bool IsCompliant
);

/// <summary>
/// Represents metadata about an audit history file stored in Azure Blob Storage.
/// Used to display available compliance reports to API consumers.
/// </summary>
internal record AuditHistoryFile(
    string FileName, 
    DateTimeOffset? CreatedOn, 
    long? SizeInBytes
);

/// <summary>
/// Response structure for successful audit date updates.
/// Returned by the PUT /audit endpoint to confirm the change.
/// </summary>
internal record AuditUpdateResponse(int AssetId, DateTime AuditDate, string Message);

/// <summary>
/// Result wrapper for audit update operations.
/// Encapsulates success/failure status, HTTP status code, response data, and error messages.
/// 
/// This pattern demonstrates:
/// - Type-safe error handling (no exceptions for validation failures)
/// - Structured responses that map cleanly to HTTP status codes
/// - Clear separation between success and error cases
/// </summary>
internal readonly struct AuditUpdateResult
{
    private AuditUpdateResult(bool isSuccess, int statusCode, AuditUpdateResponse? response, string? error)
    {
        IsSuccess = isSuccess;
        StatusCode = statusCode;
        Response = response;
        Error = error;
    }

    public bool IsSuccess { get; }
    public int StatusCode { get; }
    public AuditUpdateResponse? Response { get; }
    public string? Error { get; }

    // Factory methods for creating typed results
    public static AuditUpdateResult Ok(int assetId, DateTime auditDate) =>
        new(true, StatusCodes.Status200OK, new AuditUpdateResponse(assetId, auditDate, $"Asset {assetId} audit date updated to {auditDate:yyyy-MM-dd}."), null);

    public static AuditUpdateResult NotFound(int assetId) =>
        new(false, StatusCodes.Status404NotFound, null, $"No asset found with ID {assetId}.");

    public static AuditUpdateResult BadRequest(string message) =>
        new(false, StatusCodes.Status400BadRequest, null, message);

    /// <summary>
    /// Converts this result to an IResult for use in Minimal API endpoints.
    /// Maps to appropriate HTTP response (200 OK or error status with JSON error payload).
    /// </summary>
    public IResult ToResult() =>
        IsSuccess ? Results.Ok(Response!) : Results.Json(new { error = Error }, statusCode: StatusCode);
}
}