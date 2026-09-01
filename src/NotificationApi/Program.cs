using System.ComponentModel.DataAnnotations;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://127.0.0.1:5071");
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 16 * 1024);

var databasePath = Environment.GetEnvironmentVariable("TRIAGE_PROVIDER_DB");
if (string.IsNullOrWhiteSpace(databasePath))
{
    throw new InvalidOperationException("TRIAGE_PROVIDER_DB must identify the ignored local receipt database.");
}

var receiptStore = new ReminderReceiptStore(databasePath);
receiptStore.Initialize();
builder.Services.AddSingleton(receiptStore);

var app = builder.Build();

app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
    context.Response.ContentType = "application/problem+json";
    await context.Response.WriteAsJsonAsync(new { title = "The provider could not process the request." });
}));

app.Use(async (context, next) =>
{
    context.Response.Headers.CacheControl = "no-store";
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "triage-notification-provider" }));

app.MapPost("/api/review-reminders", async (HttpContext context, ReminderRequest body, ReminderReceiptStore store) =>
{
    var headerKey = context.Request.Headers["Idempotency-Key"].ToString();
    if (string.IsNullOrWhiteSpace(headerKey) || !string.Equals(headerKey, body.IdempotencyKey, StringComparison.Ordinal))
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
    if (body.DueAtUtc.Offset != TimeSpan.Zero)
    {
        return Results.BadRequest(new { error = "DueAtUtc must use the UTC offset." });
    }

    var requestedFailure = context.Request.Headers["X-Triage-Test-Failure"].ToString();
    if (!string.IsNullOrEmpty(requestedFailure))
    {
        var testMode = string.Equals(Environment.GetEnvironmentVariable("TRIAGE_PROVIDER_TEST_MODE"), "1", StringComparison.Ordinal);
        if (!testMode || requestedFailure is not ("after-commit-503" or "after-commit-timeout"))
        {
            return Results.BadRequest(new { error = "Failure injection is unavailable." });
        }
    }

    var decision = store.Accept(body, requestedFailure);
    if (decision.Kind == ReceiptDecisionKind.Conflict)
    {
        return Results.Conflict(new { error = "The idempotency key is already bound to a different request." });
    }

    var response = new ReminderResponse(
        decision.ReceiptId,
        body.IdempotencyKey,
        decision.Kind == ReceiptDecisionKind.Replayed,
        decision.AcceptedAtUtc);

    if (decision.InjectFailure == "after-commit-503")
    {
        return Results.Json(
            new { error = "Temporary provider failure after receipt commit.", response.ReceiptId, response.IdempotencyKey },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    if (decision.InjectFailure == "after-commit-timeout")
    {
        await Task.Delay(TimeSpan.FromSeconds(4));
    }

    return Results.Ok(response);
});

app.Run();

public partial class Program;
