<%@ Page Language="VB" AutoEventWireup="false" CodeBehind="score.aspx.vb" Inherits="Triage.Reviewer.Web.Score" %>
<!doctype html>
<html lang="en">
<head runat="server">
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" href="data:," />
    <title>Evaluation Workspace — Triage</title>
    <link rel="stylesheet" href="/admin/assets/site.css" />
</head>
<body>
<header class="topbar">
    <div><span class="brand">Triage</span><span class="environment">Local demo</span></div>
    <div><asp:Literal ID="ReviewerNameHeader" runat="server" /> · <a href="/admin/dev-login.asp">Administrator view</a></div>
</header>
<main class="workspace" id="main-content">
    <p class="eyebrow">Aster Vale Research Forum 2027</p>
    <h1>Evaluation Workspace</h1>
    <form id="scoreForm" runat="server">
        <asp:HiddenField ID="CsrfField" runat="server" />
        <asp:Panel ID="ErrorPanel" runat="server" CssClass="error-summary" Visible="false" role="alert" tabindex="-1"><asp:Literal ID="ErrorMessage" runat="server" /></asp:Panel>
        <asp:Panel ID="StatusPanel" runat="server" CssClass="status-message" Visible="false" role="status"><asp:Literal ID="StatusMessage" runat="server" /></asp:Panel>
        <asp:Panel ID="AssignmentPanel" runat="server" CssClass="abstract-card" Visible="false">
            <div class="section-heading"><span class="id-label">Abstract #<asp:Literal ID="AbstractIdText" runat="server" /></span><span class="muted">Due <asp:Literal ID="DueAtText" runat="server" /> UTC</span></div>
            <h2><asp:Literal ID="TitleText" runat="server" /></h2>
            <p><strong>Track:</strong> <asp:Literal ID="TrackText" runat="server" /></p>
            <p class="abstract-body"><asp:Literal ID="BodyText" runat="server" /></p>
            <hr />
            <fieldset>
                <legend>Score</legend>
                <asp:RadioButtonList ID="ScoreInput" runat="server" RepeatDirection="Horizontal" CssClass="score-list">
                    <asp:ListItem Value="1">1 — weak</asp:ListItem><asp:ListItem Value="2">2</asp:ListItem><asp:ListItem Value="3">3</asp:ListItem><asp:ListItem Value="4">4</asp:ListItem><asp:ListItem Value="5">5 — strong</asp:ListItem>
                </asp:RadioButtonList>
            </fieldset>
            <div class="field">
                <asp:Label ID="CommentLabel" runat="server" AssociatedControlID="CommentInput" Text="Private reviewer comment (maximum 2,000 characters)" />
                <asp:TextBox ID="CommentInput" runat="server" TextMode="MultiLine" MaxLength="2000" Rows="7" />
            </div>
            <div class="action-row">
                <asp:Button ID="SaveDraftButton" runat="server" Text="Save draft" OnClick="SaveDraftButton_Click" />
                <asp:Button ID="SubmitFinalButton" runat="server" Text="Submit final" OnClick="SubmitFinalButton_Click" />
                <asp:Button ID="DeclareConflictButton" runat="server" Text="Declare conflict" CssClass="danger-button" OnClick="DeclareConflictButton_Click" CausesValidation="false" />
            </div>
            <asp:Panel ID="ConflictConfirmation" runat="server" CssClass="notice" Visible="false">
                <p><strong>Confirm conflict declaration.</strong> This closes the assignment without submitting an evaluation.</p>
                <div class="action-row"><asp:Button ID="ConfirmConflictButton" runat="server" Text="Yes, declare conflict" CssClass="danger-button" OnClick="ConfirmConflictButton_Click" /><asp:Button ID="CancelConflictButton" runat="server" Text="Cancel" OnClick="CancelConflictButton_Click" CausesValidation="false" /></div>
            </asp:Panel>
        </asp:Panel>
    </form>
</main>
</body>
</html>
