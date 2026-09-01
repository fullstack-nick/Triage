<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit %>
<!--#include file="includes/config.asp" -->
<!--#include file="includes/db.asp" -->
<!--#include file="includes/security.asp" -->
<%
Response.Charset = "utf-8"
TriageSecurityHeaders

Dim errorMessage
errorMessage = ""

If Request.ServerVariables("REQUEST_METHOD") = "POST" Then
    Dim expectedPassword, suppliedPassword
    expectedPassword = TriageEnvironmentValue("TRIAGE_ADMIN_PASSWORD")
    suppliedPassword = CStr(Request.Form("password"))

    If Len(expectedPassword) > 0 And suppliedPassword = expectedPassword Then
        Dim connection, command, recordset
        Set connection = TriageOpenConnection()
        Set command = TriageCommand(connection, "dbo.usp_DevelopmentSession_Start")
        TriageAddParameter command, "@Email", adVarWChar, 254, "admin@aster-vale.example.test"
        TriageAddParameter command, "@ExpectedRole", adVarChar, 16, "Admin"
        Set recordset = command.Execute()

        If Not recordset.EOF Then
            Session("AdminUserId") = CLng(recordset("UserId"))
            Session("AdminRole") = CStr(recordset("UserRole"))
            Session("AdminDisplayName") = CStr(recordset("DisplayName"))
            Session("AdminCsrfToken") = CStr(recordset("CsrfToken"))
            recordset.Close
            connection.Close
            Set recordset = Nothing
            Set command = Nothing
            Set connection = Nothing
            Response.Redirect "/admin/review-queue.asp"
        End If

        If recordset.State <> 0 Then recordset.Close
        If connection.State <> 0 Then connection.Close
        Set recordset = Nothing
        Set command = Nothing
        Set connection = Nothing
    End If

    errorMessage = "The development password was not accepted. Read the generated local settings file and try again."
End If
%>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Administrator sign in — Triage</title>
    <link rel="stylesheet" href="/admin/assets/site.css">
</head>
<body class="login-page">
<main class="login-card" id="main-content">
    <p class="eyebrow">Local development access</p>
    <h1>Triage administrator</h1>
    <p>Sign in to inspect incomplete evaluation work for Aster Vale Research Forum 2027.</p>
    <% If Len(errorMessage) > 0 Then %>
        <div class="error-summary" role="alert" tabindex="-1"><%= TriageHtml(errorMessage) %></div>
    <% End If %>
    <form method="post" action="dev-login.asp" autocomplete="off">
        <div class="field">
            <label for="username">Username</label>
            <input id="username" value="admin@aster-vale.example.test" readonly>
        </div>
        <div class="field">
            <label for="password">Generated local password</label>
            <input id="password" name="password" type="password" required maxlength="200" autofocus>
        </div>
        <button type="submit">Open review queue</button>
    </form>
    <p class="muted"><a href="/reviewer/dev-login.aspx">Reviewer sign in</a></p>
</main>
</body>
</html>
