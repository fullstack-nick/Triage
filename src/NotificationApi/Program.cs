using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://127.0.0.1:5071");

var app = builder.Build();

app.Use(async (context, next) =>
{
    context.Response.Headers.CacheControl = "no-store";
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "triage-notification-provider" }));

app.MapPost("/api/review-reminders", (HttpRequest request, ReminderRequest body) =>
{
    var headerKey = request.Headers["Idempotency-Key"].ToString();
    if (string.IsNullOrWhiteSpace(headerKey) || headerKey != body.IdempotencyKey)
    {
        return Results.BadRequest(new { error = "The Idempotency-Key header must match the request body." });
    }

    var validationResults = new List<ValidationResult>();
    if (!Validator.TryValidateObject(body, new ValidationContext(body), validationResults, true))
    {
        return Results.ValidationProblem(validationResults
            .SelectMany(result => result.MemberNames.DefaultIfEmpty("request"), (result, member) => new { member, result.ErrorMessage })
            .GroupBy(item => item.member)
            .ToDictionary(group => group.Key, group => group.Select(item => item.ErrorMessage ?? "Invalid value.").ToArray()));
    }

    // The tagged legacy baseline intentionally returns a new receipt for every call.
    // INT-131 replaces this with a durable, idempotent provider receipt store.
    return Results.Ok(new ReminderResponse(
        Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant(),
        body.IdempotencyKey,
        false,
        DateTimeOffset.UtcNow));
});

app.Run();

public sealed record ReminderRequest(
    [property: Range(1, int.MaxValue)] int AssignmentId,
    [property: Required, StringLength(100, MinimumLength = 8)] string IdempotencyKey,
    [property: Required, EmailAddress, StringLength(254)] string Recipient,
    [property: Required, StringLength(160)] string EventName,
    DateTimeOffset DueAtUtc);

public sealed record ReminderResponse(
    string ReceiptId,
    string IdempotencyKey,
    bool Replayed,
    DateTimeOffset AcceptedAtUtc);

public partial class Program;
