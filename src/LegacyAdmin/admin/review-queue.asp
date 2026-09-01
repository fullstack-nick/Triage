<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit %>
<!--#include file="includes/config.asp" -->
<!--#include file="includes/db.asp" -->
<!--#include file="includes/security.asp" -->
<%
Response.Charset = "utf-8"
TriageSecurityHeaders
TriageRequireAdmin

Dim abstractFilter, trackFilter, reviewerFilter, statusFilter, filterError, flashMessage
abstractFilter = Trim(CStr(Request.QueryString("abstractId")))
trackFilter = Trim(CStr(Request.QueryString("track")))
reviewerFilter = Trim(CStr(Request.QueryString("reviewer")))
statusFilter = Trim(CStr(Request.QueryString("status")))
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
End If
Session("QueueReturnQuery") = validatedReturnQuery

If Request.ServerVariables("REQUEST_METHOD") = "POST" Then
    If Not TriageCsrfIsValid() Then
        Response.Status = "403 Forbidden"
        Response.Write "The request could not be verified. Return to the queue and try again."
        Response.End
    End If

    If CStr(Request.Form("action")) = "send-reminder" And IsNumeric(Request.Form("assignmentId")) Then
        Dim assignmentId
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
                TriageAddParameter markCommand, "@RequestStatus", adVarChar, 24, requestStatus
                TriageAddParameter markCommand, "@ProviderResponse", adVarWChar, 1000, providerResult
                markCommand.Execute

                Dim auditCommand, auditDetails
                auditDetails = "{""assignmentId"":" & assignmentId & ",""notificationId"":" & notificationId & "}"
                Set auditCommand = TriageCommand(postConnection, "dbo.usp_AuditEvent_Create")
                TriageAddParameter auditCommand, "@EntityType", adVarChar, 40, "Notification"
                TriageAddParameter auditCommand, "@EntityId", adBigInt, 0, notificationId
                TriageAddParameter auditCommand, "@Action", adVarChar, 60, "ReminderAttempted"
                TriageAddParameter auditCommand, "@PerformedByUserId", adInteger, 0, CLng(Session("AdminUserId"))
                TriageAddParameter auditCommand, "@Details", adVarWChar, 2000, auditDetails
                auditCommand.Execute
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
                                <button type="submit" class="compact">Send reminder</button>
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
        <% If rowCount = 100 And Not recordset.EOF Then %><p class="notice">This tagged baseline preview stops rendering after 100 rows while its legacy query remains intentionally unbounded.</p><% End If %>
        <% End If %>
    </section>
</main>
</body>
</html>
<%
If Not (recordset Is Nothing) Then If recordset.State <> 0 Then recordset.Close
If Not (connection Is Nothing) Then If connection.State <> 0 Then connection.Close
Set recordset = Nothing
Set command = Nothing
Set connection = Nothing
%>
