using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;

public sealed class ReminderReceiptStore
{
    private readonly string _connectionString;

    public ReminderReceiptStore(string databasePath)
    {
        var fullPath = Path.GetFullPath(databasePath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath) ?? throw new InvalidOperationException("Provider database directory is invalid."));
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = fullPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = true,
            DefaultTimeout = 10
        }.ToString();
    }

    public void Initialize()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            CREATE TABLE IF NOT EXISTS ReminderReceipt
            (
                IdempotencyKey TEXT NOT NULL PRIMARY KEY,
                RequestFingerprint TEXT NOT NULL,
                ReceiptId TEXT NOT NULL UNIQUE,
                AssignmentId INTEGER NOT NULL,
                AcceptedAtUtc TEXT NOT NULL,
                FailureMode TEXT NULL,
                FailureConsumed INTEGER NOT NULL DEFAULT 0 CHECK (FailureConsumed IN (0, 1))
            ) STRICT;
            """;
        command.ExecuteNonQuery();
    }

    public ReceiptDecision Accept(ReminderRequest request, string requestedFailure)
    {
        var fingerprint = CreateFingerprint(request);
        using var connection = OpenConnection();
        ExecuteTransactionCommand(connection, "BEGIN IMMEDIATE;");

        try
        {
            var existing = ReadExisting(connection, request.IdempotencyKey);
            if (existing is not null)
            {
                ExecuteTransactionCommand(connection, "COMMIT;");
                return string.Equals(existing.Value.Fingerprint, fingerprint, StringComparison.Ordinal)
                    ? new ReceiptDecision(ReceiptDecisionKind.Replayed, existing.Value.ReceiptId, existing.Value.AcceptedAtUtc, null)
                    : new ReceiptDecision(ReceiptDecisionKind.Conflict, existing.Value.ReceiptId, existing.Value.AcceptedAtUtc, null);
            }

            var receiptId = $"rcpt_{Guid.NewGuid():N}";
            var acceptedAtUtc = DateTimeOffset.UtcNow;
            using var insert = connection.CreateCommand();
            insert.CommandText = """
                INSERT INTO ReminderReceipt
                (
                    IdempotencyKey,
                    RequestFingerprint,
                    ReceiptId,
                    AssignmentId,
                    AcceptedAtUtc,
                    FailureMode,
                    FailureConsumed
                )
                VALUES ($key, $fingerprint, $receipt, $assignment, $accepted, $failure, $consumed);
                """;
            insert.Parameters.AddWithValue("$key", request.IdempotencyKey);
            insert.Parameters.AddWithValue("$fingerprint", fingerprint);
            insert.Parameters.AddWithValue("$receipt", receiptId);
            insert.Parameters.AddWithValue("$assignment", request.AssignmentId);
            insert.Parameters.AddWithValue("$accepted", acceptedAtUtc.ToString("O", CultureInfo.InvariantCulture));
            insert.Parameters.AddWithValue("$failure", string.IsNullOrEmpty(requestedFailure) ? DBNull.Value : requestedFailure);
            insert.Parameters.AddWithValue("$consumed", string.IsNullOrEmpty(requestedFailure) ? 0 : 1);
            insert.ExecuteNonQuery();

            ExecuteTransactionCommand(connection, "COMMIT;");
            return new ReceiptDecision(ReceiptDecisionKind.Created, receiptId, acceptedAtUtc, string.IsNullOrEmpty(requestedFailure) ? null : requestedFailure);
        }
        catch
        {
            try { ExecuteTransactionCommand(connection, "ROLLBACK;"); } catch (SqliteException) { }
            throw;
        }
    }

    public int CountByKey(string idempotencyKey)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM ReminderReceipt WHERE IdempotencyKey = $key;";
        command.Parameters.AddWithValue("$key", idempotencyKey);
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private SqliteConnection OpenConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA busy_timeout = 10000;";
        command.ExecuteNonQuery();
        return connection;
    }

    private static (string Fingerprint, string ReceiptId, DateTimeOffset AcceptedAtUtc)? ReadExisting(
        SqliteConnection connection,
        string idempotencyKey)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT RequestFingerprint, ReceiptId, AcceptedAtUtc FROM ReminderReceipt WHERE IdempotencyKey = $key;";
        command.Parameters.AddWithValue("$key", idempotencyKey);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return null;
        return (
            reader.GetString(0),
            reader.GetString(1),
            DateTimeOffset.Parse(reader.GetString(2), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind));
    }

    private static void ExecuteTransactionCommand(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static string CreateFingerprint(ReminderRequest request)
    {
        var canonical = string.Join(
            "\n",
            request.AssignmentId.ToString(CultureInfo.InvariantCulture),
            request.Recipient.Trim().ToLowerInvariant(),
            request.EventName.Trim(),
            request.DueAtUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }
}
