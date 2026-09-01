<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit %>
<!--#include file="includes/config.asp" -->
<!--#include file="includes/db.asp" -->
<!--#include file="includes/security.asp" -->
<%
Response.Charset = "utf-8"
TriageSecurityHeaders
TriageRequireAdmin

Dim abstractFilter, trackFilter, reviewerFilter, statusFilter, pageNumber, filterError, flashMessage
abstractFilter = Trim(CStr(Request.QueryString("abstractId")))
trackFilter = Trim(CStr(Request.QueryString("track")))
reviewerFilter = Trim(CStr(Request.QueryString("reviewer")))
statusFilter = Trim(CStr(Request.QueryString("status")))
pageNumber = 1
If Len(Trim(CStr(Request.QueryString("page")))) > 0 Then
    If IsNumeric(Request.QueryString("page")) Then
        pageNumber = CLng(Request.QueryString("page"))
    Else
        pageNumber = 0
    End If
End If
filterError = ""
flashMessage = CStr(Session("AdminFlash"))
Session("AdminFlash") = ""

If Len(abstractFilter) > 0 Then
    If Not IsNumeric(abstractFilter) Then
        filterError = "Abstract ID must be a positive whole number."
    ElseIf CLng(abstractFilter) < 1 Or CLng(abstractFilter) > 2147483647 Then
        filterError = "Abstract ID must be a positive whole number."
    End If
End If

If Len(trackFilter) > 80 Then filterError = "Track must be 80 characters or fewer."
If Len(reviewerFilter) > 120 Then filterError = "Reviewer must be 120 characters or fewer."
If pageNumber < 1 Or pageNumber > 2000 Then filterError = "Page number is outside the supported range."
If Len(statusFilter) > 0 And statusFilter <> "Assigned" And statusFilter <> "Draft" And statusFilter <> "Completed" And statusFilter <> "Conflict" Then
    filterError = "Choose a listed review status."
End If

Dim validatedReturnQuery
validatedReturnQuery = ""
If Len(filterError) = 0 Then
    If Len(abstractFilter) > 0 Then validatedReturnQuery = validatedReturnQuery & "abstractId=" & Server.URLEncode(abstractFilter) & "&"
    If Len(trackFilter) > 0 Then validatedReturnQuery = validatedReturnQuery & "track=" & Server.URLEncode(trackFilter) & "&"
    If Len(reviewerFilter) > 0 Then validatedReturnQuery = validatedReturnQuery & "reviewer=" & Server.URLEncode(reviewerFilter) & "&"
    If Len(statusFilter) > 0 Then validatedReturnQuery = validatedReturnQuery & "status=" & Server.URLEncode(statusFilter) & "&"
    If pageNumber > 1 Then validatedReturnQuery = validatedReturnQuery & "page=" & pageNumber & "&"
End If
If Request.ServerVariables("REQUEST_METHOD") = "GET" Then Session("QueueReturnQuery") = validatedReturnQuery

If Request.ServerVariables("REQUEST_METHOD") = "POST" Then
    If Not TriageCsrfIsValid() Then
        Response.Status = "403 Forbidden"
        Response.Write "The request could not be verified. Return to the queue and try again."
        Response.End
    End If

    Dim postAction, assignmentId
    postAction = CStr(Request.Form("action"))

    If postAction = "begin-reassign" And IsNumeric(Request.Form("assignmentId")) Then
        assignmentId = CLng(Request.Form("assignmentId"))
        If assignmentId > 0 Then
            Session("PendingReassignmentId") = assignmentId
            Session("AdminFlash") = "Choose an eligible replacement for assignment " & assignmentId & "."
        End If
    ElseIf postAction = "cancel-reassign" Then
        Session("PendingReassignmentId") = ""
        Session("AdminFlash") = "Reassignment cancelled."
    ElseIf postAction = "confirm-reassign" And IsNumeric(Request.Form("assignmentId")) And IsNumeric(Request.Form("newReviewerUserId")) Then
        assignmentId = CLng(Request.Form("assignmentId"))
        Dim newReviewerUserId, reassignConnection, reassignCommand, reassignRecordset, reassignFailed
        newReviewerUserId = CLng(Request.Form("newReviewerUserId"))
        reassignFailed = False
        Set reassignConnection = Nothing
        Set reassignCommand = Nothing
        Set reassignRecordset = Nothing

        Dim pendingReassignmentMatches
        pendingReassignmentMatches = False
        If IsNumeric(Session("PendingReassignmentId")) Then pendingReassignmentMatches = (CLng(Session("PendingReassignmentId")) = assignmentId)

        If assignmentId > 0 And newReviewerUserId > 0 And pendingReassignmentMatches Then
            On Error Resume Next
            Set reassignConnection = TriageOpenConnection()
            Set reassignCommand = TriageCommand(reassignConnection, "dbo.usp_ReviewAssignment_Reassign")
            TriageAddParameter reassignCommand, "@AssignmentId", adInteger, 0, assignmentId
            TriageAddParameter reassignCommand, "@NewReviewerUserId", adInteger, 0, newReviewerUserId
            TriageAddParameter reassignCommand, "@PerformedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
            Set reassignRecordset = reassignCommand.Execute()
            If Err.Number <> 0 Then
                reassignFailed = True
                Err.Clear
            End If
            On Error GoTo 0

            If reassignFailed Then
                Session("AdminFlash") = "The assignment could not be reassigned. Refresh the eligible reviewer list and try again."
            ElseIf Not reassignRecordset.EOF Then
                Session("AdminFlash") = "Assignment " & assignmentId & " was preserved and linked to replacement assignment " & CLng(reassignRecordset("NewAssignmentId")) & "."
            End If

            If Not (reassignRecordset Is Nothing) Then If reassignRecordset.State <> 0 Then reassignRecordset.Close
            If Not (reassignConnection Is Nothing) Then If reassignConnection.State <> 0 Then reassignConnection.Close
            Set reassignRecordset = Nothing
            Set reassignCommand = Nothing
            Set reassignConnection = Nothing
        Else
            Session("AdminFlash") = "The reassignment confirmation expired. Start again from the queue."
        End If
    ElseIf postAction = "send-reminder" And IsNumeric(Request.Form("assignmentId")) Then
        assignmentId = CLng(Request.Form("assignmentId"))

        If assignmentId > 0 Then
            Dim postConnection, createCommand, reminderRecordset
            Set postConnection = TriageOpenConnection()
            Set createCommand = TriageCommand(postConnection, "dbo.usp_ReviewReminder_Create")
            TriageAddParameter createCommand, "@AssignmentId", adInteger, 0, assignmentId
            TriageAddParameter createCommand, "@RequestedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
            Set reminderRecordset = createCommand.Execute()

            If Not reminderRecordset.EOF Then
                Dim notificationId, idempotencyKey, payload, http, providerStatus, providerResult, requestStatus
                notificationId = CLng(reminderRecordset("NotificationId"))
                idempotencyKey = CStr(reminderRecordset("IdempotencyKey"))
                payload = "{""assignmentId"":" & assignmentId & _
                    ",""idempotencyKey"":""" & TriageJsonString(idempotencyKey) & """" & _
                    ",""recipient"":""" & TriageJsonString(CStr(reminderRecordset("ReviewerEmail"))) & """" & _
                    ",""eventName"":""" & TriageJsonString(CStr(reminderRecordset("ConferenceName"))) & """" & _
                    ",""dueAtUtc"":""" & TriageIsoUtc(reminderRecordset("DueAtUtc")) & """}"

                On Error Resume Next
                Set http = Server.CreateObject("MSXML2.ServerXMLHTTP.6.0")
                http.setTimeouts 2000, 2000, 3000, 3000
                http.open "POST", TriageNotificationApiUrl(), False
                http.setRequestHeader "Content-Type", "application/json"
                http.setRequestHeader "Idempotency-Key", idempotencyKey
                http.send payload
                providerStatus = http.status
                providerResult = Left(CStr(http.responseText), 900)
                If Err.Number <> 0 Then
                    providerStatus = 0
                    providerResult = "Provider request timed out or was unavailable."
                    Err.Clear
                End If
                On Error GoTo 0

                If providerStatus >= 200 And providerStatus < 300 Then
                    requestStatus = "Succeeded"
                    Session("AdminFlash") = "Reminder accepted for assignment " & assignmentId & "."
                ElseIf providerStatus = 0 Or providerStatus >= 500 Then
                    requestStatus = "RetryableFailure"
                    Session("AdminFlash") = "The provider is temporarily unavailable. Retry the reminder."
                Else
                    requestStatus = "PermanentFailure"
                    Session("AdminFlash") = "The provider rejected the reminder request."
                End If

                Dim markCommand
                Set markCommand = TriageCommand(postConnection, "dbo.usp_ReviewReminder_MarkResult")
                TriageAddParameter markCommand, "@NotificationId", adBigInt, 0, notificationId
                TriageAddParameter markCommand, "@RequestedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
                TriageAddParameter markCommand, "@RequestStatus", adVarChar, 24, requestStatus
                TriageAddParameter markCommand, "@ProviderResponse", adVarWChar, 1000, providerResult
                markCommand.Execute
            End If

            If reminderRecordset.State <> 0 Then reminderRecordset.Close
            If postConnection.State <> 0 Then postConnection.Close
            Set reminderRecordset = Nothing
            Set createCommand = Nothing
            Set postConnection = Nothing
        End If
    End If

    Dim returnQuery
    returnQuery = CStr(Session("QueueReturnQuery"))
    If Len(returnQuery) > 0 Then returnQuery = "?" & Left(returnQuery, Len(returnQuery) - 1)
    Response.Redirect "/admin/review-queue.asp" & returnQuery
End If

Dim pendingReassignmentId, candidateConnection, candidateCommand, candidateRecordset
Dim historyConnection, historyCommand, historyRecordset
pendingReassignmentId = 0
Set candidateConnection = Nothing
Set candidateCommand = Nothing
Set candidateRecordset = Nothing
Set historyConnection = Nothing
Set historyCommand = Nothing
Set historyRecordset = Nothing

If IsNumeric(Session("PendingReassignmentId")) Then pendingReassignmentId = CLng(Session("PendingReassignmentId"))
If pendingReassignmentId > 0 Then
    On Error Resume Next
    Set candidateConnection = TriageOpenConnection()
    Set candidateCommand = TriageCommand(candidateConnection, "dbo.usp_ReviewReassignment_Candidates_Get")
    TriageAddParameter candidateCommand, "@AssignmentId", adInteger, 0, pendingReassignmentId
    TriageAddParameter candidateCommand, "@PerformedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
    TriageAddParameter candidateCommand, "@IncludeAudit", adBoolean, 0, False
    Set candidateRecordset = candidateCommand.Execute()

    Set historyConnection = TriageOpenConnection()
    Set historyCommand = TriageCommand(historyConnection, "dbo.usp_ReviewReassignment_Candidates_Get")
    TriageAddParameter historyCommand, "@AssignmentId", adInteger, 0, pendingReassignmentId
    TriageAddParameter historyCommand, "@PerformedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
    TriageAddParameter historyCommand, "@IncludeAudit", adBoolean, 0, True
    Set historyRecordset = historyCommand.Execute()
    If Err.Number <> 0 Then Err.Clear
    On Error GoTo 0
End If

Dim connection, command, recordset
Set connection = Nothing
Set command = Nothing
Set recordset = Nothing
If Len(filterError) = 0 Then
    Set connection = TriageOpenConnection()
    Set command = TriageCommand(connection, "dbo.usp_AtRiskReviewQueue_Get")
    If Len(abstractFilter) > 0 Then
        TriageAddParameter command, "@AbstractId", adInteger, 0, CLng(abstractFilter)
    Else
        TriageAddParameter command, "@AbstractId", adInteger, 0, Null
    End If
    If Len(trackFilter) > 0 Then
        TriageAddParameter command, "@Track", adVarWChar, 80, trackFilter
    Else
        TriageAddParameter command, "@Track", adVarWChar, 80, Null
    End If
    If Len(reviewerFilter) > 0 Then
        TriageAddParameter command, "@Reviewer", adVarWChar, 120, reviewerFilter
    Else
        TriageAddParameter command, "@Reviewer", adVarWChar, 120, Null
    End If
    If Len(statusFilter) > 0 Then
        TriageAddParameter command, "@ReviewStatus", adVarChar, 20, statusFilter
    Else
        TriageAddParameter command, "@ReviewStatus", adVarChar, 20, Null
    End If
    TriageAddParameter command, "@PageNumber", adInteger, 0, pageNumber
    TriageAddParameter command, "@PageSize", adInteger, 0, 50
    TriageAddParameter command, "@AsOfUtc", adDBTimeStamp, 0, Null
    Set recordset = command.Execute()
End If
%>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Review Triage Queue</title>
    <link rel="stylesheet" href="/admin/assets/site.css">
</head>
<body>
<header class="topbar">
    <div><span class="brand">Triage</span><span class="environment">Local demo</span></div>
    <div><span><%= TriageHtml(Session("AdminDisplayName")) %></span> · <a href="/reviewer/dev-login.aspx">Reviewer view</a></div>
</header>
<main id="main-content" class="shell">
    <div class="page-heading">
        <div><p class="eyebrow">Aster Vale Research Forum 2027</p><h1>Review Triage Queue</h1></div>
        <p class="lede">Find active abstracts that have fewer final evaluations than required.</p>
    </div>

    <% If Len(filterError) > 0 Then %><div class="error-summary" role="alert" tabindex="-1"><%= TriageHtml(filterError) %></div><% End If %>
    <% If Len(flashMessage) > 0 Then %><div class="status-message" role="status"><%= TriageHtml(flashMessage) %></div><% End If %>

    <% If pendingReassignmentId > 0 And Not (candidateRecordset Is Nothing) Then %>
    <section class="panel" id="reassignment" aria-labelledby="reassignment-heading" tabindex="-1">
        <p class="eyebrow">Preserve assignment history</p>
        <h2 id="reassignment-heading">Reassign assignment <%= pendingReassignmentId %></h2>
        <% If Not candidateRecordset.EOF Then %>
        <form method="post" class="reassignment-form">
            <input type="hidden" name="csrfToken" value="<%= TriageHtml(Session("AdminCsrfToken")) %>">
            <input type="hidden" name="assignmentId" value="<%= pendingReassignmentId %>">
            <div class="field">
                <label for="newReviewerUserId">Eligible replacement reviewer</label>
                <select id="newReviewerUserId" name="newReviewerUserId" required autofocus>
                    <option value="">Choose a reviewer</option>
                    <% Do Until candidateRecordset.EOF %>
                        <option value="<%= CLng(candidateRecordset("UserId")) %>"><%= TriageHtml(candidateRecordset("DisplayName")) %></option>
                    <% candidateRecordset.MoveNext : Loop %>
                </select>
                <span class="muted">Inactive, conflicted, current, and previously assigned reviewers are excluded by the database.</span>
            </div>
            <div class="action-row">
                <button type="submit" name="action" value="confirm-reassign">Confirm reassignment</button>
                <button type="submit" name="action" value="cancel-reassign" class="secondary-button" formnovalidate>Cancel</button>
            </div>
        </form>
        <% Else %>
            <p>No eligible replacement is available, or the assignment is no longer open.</p>
            <form method="post"><input type="hidden" name="csrfToken" value="<%= TriageHtml(Session("AdminCsrfToken")) %>"><button type="submit" name="action" value="cancel-reassign" class="secondary-button">Close</button></form>
        <% End If %>

        <% If Not (historyRecordset Is Nothing) Then %>
            <% If Not historyRecordset.EOF Then %>
            <h3>Newest audit activity</h3>
            <ul class="audit-list">
                <% Do Until historyRecordset.EOF %>
                    <li><strong><%= TriageHtml(historyRecordset("Action")) %></strong> by <%= TriageHtml(historyRecordset("PerformedBy")) %> at <%= TriageHtml(TriageIsoUtc(historyRecordset("OccurredAtUtc"))) %></li>
                <% historyRecordset.MoveNext : Loop %>
            </ul>
            <% End If %>
        <% End If %>
    </section>
    <% End If %>

    <section class="panel" aria-labelledby="filter-heading">
        <h2 id="filter-heading">Filter queue</h2>
        <form method="get" class="filter-grid">
            <div class="field"><label for="abstractId">Abstract ID</label><input id="abstractId" name="abstractId" inputmode="numeric" value="<%= TriageHtml(abstractFilter) %>"></div>
            <div class="field"><label for="track">Track</label><input id="track" name="track" maxlength="80" value="<%= TriageHtml(trackFilter) %>"></div>
            <div class="field"><label for="reviewer">Assigned reviewer</label><input id="reviewer" name="reviewer" maxlength="120" value="<%= TriageHtml(reviewerFilter) %>"></div>
            <div class="field"><label for="status">Review status</label><select id="status" name="status"><option value="">Any active status</option><option value="Assigned"<% If statusFilter="Assigned" Then Response.Write " selected" %>>Assigned</option><option value="Draft"<% If statusFilter="Draft" Then Response.Write " selected" %>>Draft</option><option value="Completed"<% If statusFilter="Completed" Then Response.Write " selected" %>>Completed</option><option value="Conflict"<% If statusFilter="Conflict" Then Response.Write " selected" %>>Conflict</option></select></div>
            <div class="filter-actions"><button type="submit">Apply filters</button><a class="button secondary" href="review-queue.asp">Clear</a></div>
        </form>
    </section>

    <section class="panel table-panel" aria-labelledby="results-heading">
        <div class="section-heading"><h2 id="results-heading">Incomplete evaluations</h2><span class="muted">UTC deadlines</span></div>
        <% If Len(filterError) = 0 Then %>
        <div class="table-wrap">
            <table>
                <caption>Active abstracts requiring additional final evaluations</caption>
                <thead><tr><th scope="col">Abstract</th><th scope="col">Track</th><th scope="col">Progress</th><th scope="col">Assignments</th><th scope="col">Action</th></tr></thead>
                <tbody>
                <%
                Dim rowCount
                rowCount = 0
                Do Until recordset.EOF Or rowCount >= 100
                    rowCount = rowCount + 1
                %>
                    <tr>
                        <th scope="row"><span class="id-label">#<%= CLng(recordset("AbstractId")) %></span><%= TriageHtml(recordset("Title")) %></th>
                        <td><%= TriageHtml(recordset("Track")) %></td>
                        <td><strong><%= CLng(recordset("CompletedReviewCount")) %>/<%= CInt(recordset("RequiredReviewCount")) %></strong> final</td>
                        <td class="assignment-summary"><%= TriageHtml(recordset("AssignmentSummary")) %></td>
                        <td>
                        <% If Not IsNull(recordset("ActionAssignmentId")) Then %>
                            <form method="post" class="inline-form">
                                <input type="hidden" name="csrfToken" value="<%= TriageHtml(Session("AdminCsrfToken")) %>">
                                <input type="hidden" name="action" value="send-reminder">
                                <input type="hidden" name="assignmentId" value="<%= CLng(recordset("ActionAssignmentId")) %>">
                                <button type="submit" class="compact">Send or retry reminder</button>
                            </form>
                            <form method="post" class="inline-form reassign-inline">
                                <input type="hidden" name="csrfToken" value="<%= TriageHtml(Session("AdminCsrfToken")) %>">
                                <input type="hidden" name="action" value="begin-reassign">
                                <input type="hidden" name="assignmentId" value="<%= CLng(recordset("ActionAssignmentId")) %>">
                                <button type="submit" class="compact secondary-button">Reassign</button>
                            </form>
                        <% Else %><span class="muted">No open assignment</span><% End If %>
                        </td>
                    </tr>
                <%
                    recordset.MoveNext
                Loop
                If rowCount = 0 Then
                %><tr><td colspan="5">No incomplete evaluations match these filters.</td></tr><%
                End If
                %>
                </tbody>
            </table>
        </div>
        <nav class="pager" aria-label="Queue pages">
            <%
            Dim filterPrefix, previousPage, nextPage
            filterPrefix = ""
            If Len(abstractFilter) > 0 Then filterPrefix = filterPrefix & "abstractId=" & Server.URLEncode(abstractFilter) & "&"
            If Len(trackFilter) > 0 Then filterPrefix = filterPrefix & "track=" & Server.URLEncode(trackFilter) & "&"
            If Len(reviewerFilter) > 0 Then filterPrefix = filterPrefix & "reviewer=" & Server.URLEncode(reviewerFilter) & "&"
            If Len(statusFilter) > 0 Then filterPrefix = filterPrefix & "status=" & Server.URLEncode(statusFilter) & "&"
            previousPage = pageNumber - 1
            nextPage = pageNumber + 1
            %>
            <% If pageNumber > 1 Then %><a class="button secondary" href="?<%= filterPrefix %>page=<%= previousPage %>">Previous page</a><% End If %>
            <span>Page <strong><%= pageNumber %></strong></span>
            <% If rowCount = 50 Then %><a class="button secondary" href="?<%= filterPrefix %>page=<%= nextPage %>">Next page</a><% End If %>
        </nav>
        <% End If %>
    </section>
</main>
</body>
</html>
<%
If Not (recordset Is Nothing) Then If recordset.State <> 0 Then recordset.Close
If Not (connection Is Nothing) Then If connection.State <> 0 Then connection.Close
If Not (candidateRecordset Is Nothing) Then If candidateRecordset.State <> 0 Then candidateRecordset.Close
If Not (candidateConnection Is Nothing) Then If candidateConnection.State <> 0 Then candidateConnection.Close
If Not (historyRecordset Is Nothing) Then If historyRecordset.State <> 0 Then historyRecordset.Close
If Not (historyConnection Is Nothing) Then If historyConnection.State <> 0 Then historyConnection.Close
Set recordset = Nothing
Set command = Nothing
Set connection = Nothing
Set candidateRecordset = Nothing
Set candidateCommand = Nothing
Set candidateConnection = Nothing
Set historyRecordset = Nothing
Set historyCommand = Nothing
Set historyConnection = Nothing
%>
