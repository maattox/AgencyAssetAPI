using System.Data;
using Azure.Core;
using Azure.Identity;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Data.SqlClient;

namespace AgencyAssetAPI;

internal static class AssetDataAccess
{
    private static readonly Lazy<DefaultAzureCredential> _azureCredential =
        new(() => new DefaultAzureCredential());

    /// Open a SqlConnection, injecting a Managed Identity token manually
    /// when the connection string uses pure passwordless settings.
    private static async Task<SqlConnection> OpenConnectionAsync(string connectionString, CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(connectionString);
        var builder = new SqlConnectionStringBuilder(connectionString);

        // If no SQL User or Password is provided, use Azure Managed Identity token injection
        if (string.IsNullOrEmpty(builder.UserID) && string.IsNullOrEmpty(builder.Password))
        {
            var tokenRequestContext = new TokenRequestContext(["https://database.windows.net/.default"]);
            var accessToken = await _azureCredential.Value.GetTokenAsync(tokenRequestContext, cancellationToken);
            connection.AccessToken = accessToken.Token;
        }

        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    internal static bool CheckCompliance(DateTime? lastAuditDate, int maxDays)
    {
        if (!lastAuditDate.HasValue)
            return false;

        var daysSinceLastAudit = (DateTime.UtcNow - lastAuditDate.Value).TotalDays;
        return daysSinceLastAudit <= maxDays;
    }

    internal static async Task<List<Asset>> GetAllAssetsAsync(string connectionString, int maxDays, CancellationToken cancellationToken = default)
    {
        var assets = new List<Asset>();

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        await using var command = new SqlCommand("SELECT AssetId, SerialNumber, AssetName, AssignedDepartment, LastAuditDate FROM Assets", connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            assets.Add(ReadAsset(reader, maxDays));
        }

        return assets;
    }

    internal static async Task<List<Asset>> GetNonAuditedAssetsAsync(string connectionString, int maxDays, CancellationToken cancellationToken = default)
    {
        var assets = new List<Asset>();

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        await using var command = new SqlCommand("GetNonAuditedAssets", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        command.Parameters.Add("@MaxDaysSinceLastAudit", SqlDbType.Int).Value = maxDays;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            assets.Add(ReadAsset(reader, maxDays));
        }

        return assets;
    }

    internal static async Task<AuditUpdateResult> UpdateAuditDateAsync(string connectionString, int id, DateTime? auditDate, CancellationToken cancellationToken = default)
    {
        if (auditDate.HasValue && auditDate.Value > DateTime.UtcNow)
            return AuditUpdateResult.BadRequest("Audit date cannot be in the future.");

        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        await using var selectCommand = new SqlCommand("SELECT LastAuditDate FROM Assets WHERE AssetId = @Id", connection);
        selectCommand.Parameters.Add("@Id", SqlDbType.Int).Value = id;

        var result = await selectCommand.ExecuteScalarAsync(cancellationToken);

        if (result is null)
            return AuditUpdateResult.NotFound(id);

        if (auditDate.HasValue && result is not DBNull)
        {
            var currentAuditDate = (DateTime)result;
            if (auditDate.Value < currentAuditDate)
            {
                return AuditUpdateResult.BadRequest(
                    $"Audit date cannot be earlier than the current audit date ({currentAuditDate:yyyy-MM-dd}).");
            }
        }

        var auditDateToSet = auditDate ?? DateTime.UtcNow;

        await using var command = new SqlCommand("UPDATE Assets SET LastAuditDate = @AuditDate WHERE AssetId = @Id", connection);
        command.Parameters.Add("@AuditDate", SqlDbType.DateTime).Value = auditDateToSet;
        command.Parameters.Add("@Id", SqlDbType.Int).Value = id;

        await command.ExecuteNonQueryAsync(cancellationToken);

        return AuditUpdateResult.Ok(id, auditDateToSet);
    }

    internal static async Task ResetAssetsTableAsync(string connectionString, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);

        await using var command = new SqlCommand("ResetAssetsTable", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    internal static async Task<bool> CanConnectAsync(string connectionString, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(connectionString, cancellationToken);
        return true;
    }

    private static Asset ReadAsset(SqlDataReader reader, int maxDays)
    {
        var ordAssetId = reader.GetOrdinal("AssetId");
        var ordSerial = reader.GetOrdinal("SerialNumber");
        var ordName = reader.GetOrdinal("AssetName");
        var ordDept = reader.GetOrdinal("AssignedDepartment");
        var ordLastAudit = reader.GetOrdinal("LastAuditDate");

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
}

internal record Asset(
    int AssetId,
    string SerialNumber,
    string? AssetName,
    string? AssignedDepartment,
    DateTime? LastAuditDate,
    bool IsCompliant
);

internal record AuditUpdateResponse(int AssetId, DateTime AuditDate, string Message);

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

    public static AuditUpdateResult Ok(int assetId, DateTime auditDate) =>
        new(true, StatusCodes.Status200OK, new AuditUpdateResponse(assetId, auditDate, $"Asset {assetId} audit date updated to {auditDate:yyyy-MM-dd}."), null);

    public static AuditUpdateResult NotFound(int assetId) =>
        new(false, StatusCodes.Status404NotFound, null, $"No asset found with ID {assetId}.");

    public static AuditUpdateResult BadRequest(string message) =>
        new(false, StatusCodes.Status400BadRequest, null, message);

    public IResult ToResult() =>
        IsSuccess ? Results.Ok(Response!) : Results.Json(new { error = Error }, statusCode: StatusCode);
}