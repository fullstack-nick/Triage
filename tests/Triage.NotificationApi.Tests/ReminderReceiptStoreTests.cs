using Xunit;

public sealed class ReminderReceiptStoreTests : IDisposable
{
    private readonly string _databasePath = Path.Combine(
        Path.GetTempPath(),
        $"triage-provider-test-{Guid.NewGuid():N}.db");

    [Fact]
    public async Task Concurrent_requests_share_one_durable_receipt()
    {
        var store = CreateStore();
        var request = NewRequest($"concurrent-{Guid.NewGuid():N}");

        var decisions = await Task.WhenAll(
            Enumerable.Range(0, 20).Select(_ => Task.Run(() => store.Accept(request, string.Empty))));

        Assert.Single(decisions.Select(decision => decision.ReceiptId).Distinct(StringComparer.Ordinal));
        Assert.Single(decisions, decision => decision.Kind == ReceiptDecisionKind.Created);
        Assert.Equal(19, decisions.Count(decision => decision.Kind == ReceiptDecisionKind.Replayed));
        Assert.Equal(1, store.CountByKey(request.IdempotencyKey));
    }

    [Fact]
    public void Same_key_with_different_payload_is_a_conflict()
    {
        var store = CreateStore();
        var request = NewRequest($"conflict-{Guid.NewGuid():N}");
        var created = store.Accept(request, string.Empty);
        var changed = request with { Recipient = "another-reviewer@example.test" };

        var conflict = store.Accept(changed, string.Empty);

        Assert.Equal(ReceiptDecisionKind.Created, created.Kind);
        Assert.Equal(ReceiptDecisionKind.Conflict, conflict.Kind);
        Assert.Equal(created.ReceiptId, conflict.ReceiptId);
        Assert.Equal(1, store.CountByKey(request.IdempotencyKey));
    }

    [Fact]
    public void Receipt_survives_store_restart()
    {
        var request = NewRequest($"restart-{Guid.NewGuid():N}");
        var firstStore = CreateStore();
        var created = firstStore.Accept(request, string.Empty);

        var restartedStore = new ReminderReceiptStore(_databasePath);
        restartedStore.Initialize();
        var replay = restartedStore.Accept(request, string.Empty);

        Assert.Equal(ReceiptDecisionKind.Replayed, replay.Kind);
        Assert.Equal(created.ReceiptId, replay.ReceiptId);
        Assert.Equal(1, restartedStore.CountByKey(request.IdempotencyKey));
    }

    [Fact]
    public void After_commit_failure_is_consumed_once()
    {
        var store = CreateStore();
        var request = NewRequest($"failure-{Guid.NewGuid():N}");

        var first = store.Accept(request, "after-commit-503");
        var retry = store.Accept(request, "after-commit-503");

        Assert.Equal("after-commit-503", first.InjectFailure);
        Assert.Null(retry.InjectFailure);
        Assert.Equal(ReceiptDecisionKind.Replayed, retry.Kind);
        Assert.Equal(first.ReceiptId, retry.ReceiptId);
        Assert.Equal(1, store.CountByKey(request.IdempotencyKey));
    }

    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        foreach (var suffix in new[] { string.Empty, "-wal", "-shm" })
        {
            var target = _databasePath + suffix;
            if (File.Exists(target)) File.Delete(target);
        }
    }

    private ReminderReceiptStore CreateStore()
    {
        var store = new ReminderReceiptStore(_databasePath);
        store.Initialize();
        return store;
    }

    private static ReminderRequest NewRequest(string key) => new(
        101,
        key,
        "reviewer101@example.test",
        "Aster Vale Research Forum 2027",
        DateTimeOffset.Parse("2027-03-15T17:00:00Z"));
}
