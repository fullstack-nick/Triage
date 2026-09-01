<%@ Page Language="VB" AutoEventWireup="false" CodeBehind="dev-login.aspx.vb" Inherits="Triage.Reviewer.Web.DevLogin" %>
<!doctype html>
<html lang="en">
<head runat="server">
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" href="data:," />
    <title>Reviewer sign in — Triage</title>
    <link rel="stylesheet" href="/admin/assets/site.css" />
</head>
<body class="login-page">
<main class="login-card" id="main-content">
    <p class="eyebrow">Local development access</p>
    <h1>Evaluation Workspace</h1>
    <p>Use the generated local password to open Reviewer 001's fictional assignment.</p>
    <form id="loginForm" runat="server" autocomplete="off">
        <asp:Panel ID="ErrorPanel" runat="server" CssClass="error-summary" Visible="false" role="alert">
            <asp:Literal ID="ErrorMessage" runat="server" />
        </asp:Panel>
        <asp:HiddenField ID="CsrfField" runat="server" />
        <div class="field">
            <label for="Username">Username</label>
            <input id="Username" value="reviewer001@example.test" readonly />
        </div>
        <div class="field">
            <asp:Label ID="PasswordLabel" runat="server" AssociatedControlID="PasswordInput" Text="Generated local password" />
            <asp:TextBox ID="PasswordInput" runat="server" TextMode="Password" MaxLength="200" required="required" autofocus="autofocus" />
        </div>
        <asp:Button ID="LoginButton" runat="server" Text="Open assignment" OnClick="LoginButton_Click" />
    </form>
    <p class="muted"><a href="/admin/dev-login.asp">Administrator sign in</a></p>
</main>
</body>
</html>
