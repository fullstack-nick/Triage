using System.ComponentModel.DataAnnotations;

public sealed record ReminderRequest(
    [property: Range(1, int.MaxValue)] int AssignmentId,
    [property: Required, StringLength(100, MinimumLength = 8), RegularExpression("^[a-z0-9-]+$")] string IdempotencyKey,
    [property: Required, EmailAddress, StringLength(254)] string Recipient,
    [property: Required, StringLength(160, MinimumLength = 1)] string EventName,
    DateTimeOffset DueAtUtc);

public sealed record ReminderResponse(
    string ReceiptId,
    string IdempotencyKey,
    bool Replayed,
    DateTimeOffset AcceptedAtUtc);

public enum ReceiptDecisionKind
{
    Created,
    Replayed,
    Conflict
}

public sealed record ReceiptDecision(
    ReceiptDecisionKind Kind,
    string ReceiptId,
    DateTimeOffset AcceptedAtUtc,
    string? InjectFailure);
