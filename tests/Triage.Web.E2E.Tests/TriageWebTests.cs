using System.Net;
using System.Text;
using Microsoft.Playwright;
using Xunit;

public sealed class TriageWebTests
{
    private const string BaseUrl = "http://127.0.0.1:5070";

    [Fact(DisableParallelization = true)]
    public async Task AdministratorQueueUsesBoundedRowsEncodingAndCsrf()
    {
        using var playwright = await Playwright.CreateAsync();
        await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
        {
            Channel = "msedge",
            Headless = true
        });
        await using var context = await browser.NewContextAsync(new BrowserNewContextOptions
        {
            BaseURL = BaseUrl,
            ViewportSize = new ViewportSize { Width = 1440, Height = 1000 }
        });
        var page = await context.NewPageAsync();
        var dialogMessages = new List<string>();
        var consoleErrors = new List<string>();
        page.Dialog += (_, dialog) =>
        {
            dialogMessages.Add(dialog.Message);
            _ = dialog.DismissAsync();
        };
        page.Console += (_, message) =>
        {
            if (message.Type == "error") consoleErrors.Add(message.Text);
        };

        var loginResponse = await page.GotoAsync("/admin/dev-login.asp");
        Assert.NotNull(loginResponse);
        Assert.Equal(200, loginResponse.Status);
        await AssertSecurityHeadersAsync(loginResponse);

        var adminPassword = RequiredEnvironment("TRIAGE_ADMIN_PASSWORD");
        await page.GetByLabel("Generated local password").FillAsync(adminPassword);
        await page.Locator("input[name=csrfToken]").EvaluateAsync("element => element.value = 'invalid'");
        await page.GetByRole(AriaRole.Button, new() { Name = "Open review queue" }).ClickAsync();
        Assert.Contains("request could not be verified", await page.GetByRole(AriaRole.Alert).InnerTextAsync(), StringComparison.OrdinalIgnoreCase);

        await page.GotoAsync("/admin/dev-login.asp");
        await page.GetByLabel("Generated local password").FillAsync(adminPassword);
        await page.GetByRole(AriaRole.Button, new() { Name = "Open review queue" }).ClickAsync();
        await page.WaitForURLAsync("**/admin/review-queue.asp");

        Assert.Equal("Review Triage Queue", (await page.GetByRole(AriaRole.Heading, new() { Level = 1 }).InnerTextAsync()).Trim());
        var rows = page.Locator("tbody tr");
        var rowCount = await rows.CountAsync();
        Assert.InRange(rowCount, 1, 50);
        Assert.Contains("Page 1", await page.Locator("nav.pager").InnerTextAsync());

        await page.GetByLabel("Abstract ID").FillAsync("13");
        await page.GetByRole(AriaRole.Button, new() { Name = "Apply filters" }).ClickAsync();
        await page.WaitForURLAsync("**abstractId=13**");

        var encodedFixtureText = await page.Locator("tbody tr").InnerTextAsync();
        Assert.Contains("<script>alert('triage')</script> — encoded fixture", encodedFixtureText, StringComparison.Ordinal);
        Assert.Equal(0, await page.Locator("tbody script").CountAsync());
        Assert.Empty(dialogMessages);
        Assert.Empty(consoleErrors);

        var actionForm = page.Locator("form.inline-form").First;
        await actionForm.Locator("input[name=csrfToken]").EvaluateAsync("element => element.value = 'invalid'");
        var csrfResponseTask = page.WaitForResponseAsync(response =>
            response.Request.Method == "POST" && response.Url.Contains("review-queue.asp", StringComparison.OrdinalIgnoreCase));
        await actionForm.GetByRole(AriaRole.Button).ClickAsync();
        var csrfResponse = await csrfResponseTask;
        Assert.Equal(403, csrfResponse.Status);
        Assert.Contains("request could not be verified", await page.TextContentAsync("body") ?? string.Empty, StringComparison.OrdinalIgnoreCase);
    }

    [Fact(DisableParallelization = true)]
    public async Task ReviewerBoundaryHidesAuthorsRejectsForeignWorkAndProtectsEveryAction()
    {
        using var playwright = await Playwright.CreateAsync();
        await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
        {
            Channel = "msedge",
            Headless = true
        });
        await using var context = await browser.NewContextAsync(new BrowserNewContextOptions
        {
            BaseURL = BaseUrl,
            ViewportSize = new ViewportSize { Width = 1440, Height = 1000 }
        });
        var page = await context.NewPageAsync();
        var consoleErrors = new List<string>();
        page.Console += (_, message) =>
        {
            if (message.Type == "error") consoleErrors.Add(message.Text);
        };

        var loginResponse = await page.GotoAsync("/reviewer/dev-login.aspx");
        Assert.NotNull(loginResponse);
        Assert.Equal(200, loginResponse.Status);
        await AssertSecurityHeadersAsync(loginResponse);

        var reviewerPassword = RequiredEnvironment("TRIAGE_REVIEWER_PASSWORD");
        await page.GetByLabel("Generated local password").FillAsync(reviewerPassword);
        await page.Locator("#CsrfField").EvaluateAsync("element => element.value = 'invalid'");
        await page.GetByRole(AriaRole.Button, new() { Name = "Open assignment" }).ClickAsync();
        Assert.Contains("request could not be verified", await page.GetByRole(AriaRole.Alert).InnerTextAsync(), StringComparison.OrdinalIgnoreCase);

        await page.GotoAsync("/reviewer/dev-login.aspx");
        await page.GetByLabel("Generated local password").FillAsync(reviewerPassword);
        await page.GetByRole(AriaRole.Button, new() { Name = "Open assignment" }).ClickAsync();
        await page.WaitForURLAsync("**/reviewer/score.aspx?id=1");

        var ownedHtml = await page.ContentAsync();
        Assert.DoesNotContain("PRIVATE-AUTHOR", ownedHtml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-author-", ownedHtml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Evidence synthesis abstract 00001", await page.Locator(".abstract-card").InnerTextAsync());
        await AssertViewStateHasNoAuthorSentinelAsync(page);

        foreach (var buttonName in new[] { "Save draft", "Submit final" })
        {
            await page.GotoAsync("/reviewer/score.aspx?id=1");
            await page.Locator("#CsrfField").EvaluateAsync("element => element.value = 'invalid'");
            await page.GetByRole(AriaRole.Button, new() { Name = buttonName, Exact = true }).ClickAsync();
            Assert.Contains("request could not be verified", await page.GetByRole(AriaRole.Alert).InnerTextAsync(), StringComparison.OrdinalIgnoreCase);
        }

        await page.GotoAsync("/reviewer/score.aspx?id=1");
        await page.GetByRole(AriaRole.Button, new() { Name = "Declare conflict", Exact = true }).ClickAsync();
        await page.Locator("#CsrfField").EvaluateAsync("element => element.value = 'invalid'");
        await page.GetByRole(AriaRole.Button, new() { Name = "Yes, declare conflict", Exact = true }).ClickAsync();
        Assert.Contains("request could not be verified", await page.GetByRole(AriaRole.Alert).InnerTextAsync(), StringComparison.OrdinalIgnoreCase);

        var foreignGet = await ReadNotFoundAsync(page, 2);
        var missingGet = await ReadNotFoundAsync(page, 2_000_000_000);
        Assert.Equal(missingGet, foreignGet);

        var foreignPost = await PostDraftAsync(context, page, 2);
        var missingPost = await PostDraftAsync(context, page, 2_000_000_000);
        Assert.Equal(HttpStatusCode.Found, foreignPost.StatusCode);
        Assert.Equal(missingPost.StatusCode, foreignPost.StatusCode);
        Assert.Equal(missingPost.Location, foreignPost.Location);
        Assert.Contains("dev-login.aspx", foreignPost.Location, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("PRIVATE-AUTHOR", foreignPost.Body, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(consoleErrors);
    }

    private static async Task AssertSecurityHeadersAsync(IResponse response)
    {
        var headers = await response.AllHeadersAsync();
        Assert.Contains("no-store", headers["cache-control"], StringComparison.OrdinalIgnoreCase);
        Assert.Equal("nosniff", headers["x-content-type-options"]);
        Assert.Equal("DENY", headers["x-frame-options"]);
        Assert.Equal("no-referrer", headers["referrer-policy"]);
    }

    private static async Task AssertViewStateHasNoAuthorSentinelAsync(IPage page)
    {
        var fields = page.Locator("input[name^=__VIEWSTATE]");
        for (var index = 0; index < await fields.CountAsync(); index++)
        {
            var encoded = await fields.Nth(index).InputValueAsync();
            var decoded = Convert.FromBase64String(encoded);
            Assert.DoesNotContain("PRIVATE-AUTHOR", Encoding.UTF8.GetString(decoded), StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("PRIVATE-AUTHOR", Encoding.Unicode.GetString(decoded), StringComparison.OrdinalIgnoreCase);
        }
    }

    private static async Task<string> ReadNotFoundAsync(IPage page, int assignmentId)
    {
        await page.GotoAsync($"/reviewer/score.aspx?id={assignmentId}");
        var html = await page.ContentAsync();
        Assert.DoesNotContain("Evidence synthesis abstract", html, StringComparison.Ordinal);
        Assert.DoesNotContain("PRIVATE-AUTHOR", html, StringComparison.OrdinalIgnoreCase);
        return (await page.GetByRole(AriaRole.Alert).InnerTextAsync()).Trim();
    }

    private static async Task<(HttpStatusCode StatusCode, string Location, string Body)> PostDraftAsync(
        IBrowserContext context,
        IPage page,
        int assignmentId)
    {
        await page.GotoAsync($"/reviewer/score.aspx?id={assignmentId}");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var inputs = page.Locator("form input[type=hidden]");
        for (var index = 0; index < await inputs.CountAsync(); index++)
        {
            var input = inputs.Nth(index);
            var name = await input.GetAttributeAsync("name");
            if (!string.IsNullOrEmpty(name)) fields[name] = await input.InputValueAsync();
        }
        fields["SaveDraftButton"] = "Save draft";

        var cookies = await context.CookiesAsync();
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
        using var client = new HttpClient(handler);
        client.DefaultRequestHeaders.TryAddWithoutValidation("Cookie", string.Join("; ", cookies.Select(cookie => $"{cookie.Name}={cookie.Value}")));
        using var response = await client.PostAsync($"{BaseUrl}/reviewer/score.aspx?id={assignmentId}", new FormUrlEncodedContent(fields));
        return (
            response.StatusCode,
            response.Headers.Location?.ToString() ?? string.Empty,
            await response.Content.ReadAsStringAsync());
    }

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"{name} must be loaded from the ignored local settings before E2E tests run.");
}
