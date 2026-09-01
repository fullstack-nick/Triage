<%
Sub TriageSecurityHeaders()
    Response.AddHeader "Cache-Control", "no-store, max-age=0"
    Response.AddHeader "Pragma", "no-cache"
    Response.AddHeader "X-Content-Type-Options", "nosniff"
    Response.AddHeader "X-Frame-Options", "DENY"
    Response.AddHeader "Referrer-Policy", "no-referrer"
End Sub

Sub TriageRequireAdmin()
    If CStr(Session("AdminRole")) <> "Admin" Or Len(CStr(Session("AdminUserId"))) = 0 Then
        Response.Redirect "/admin/dev-login.asp"
    End If
End Sub

Function TriageCsrfIsValid()
    Dim expected, supplied
    expected = CStr(Session("AdminCsrfToken"))
    supplied = CStr(Request.Form("csrfToken"))
    TriageCsrfIsValid = (Len(expected) = 64 And Len(supplied) = 64 And expected = supplied)
End Function

Function TriageHtml(ByVal value)
    If IsNull(value) Then
        TriageHtml = ""
    Else
        TriageHtml = Server.HTMLEncode(CStr(value))
    End If
End Function

Function TriageJsonString(ByVal value)
    Dim text
    text = CStr(value)
    text = Replace(text, "\", "\\")
    text = Replace(text, Chr(34), "\" & Chr(34))
    text = Replace(text, vbCr, "\r")
    text = Replace(text, vbLf, "\n")
    TriageJsonString = text
End Function

Function TriageIsoUtc(ByVal value)
    TriageIsoUtc = Year(value) & "-" & Right("0" & Month(value), 2) & "-" & Right("0" & Day(value), 2) & _
        "T" & Right("0" & Hour(value), 2) & ":" & Right("0" & Minute(value), 2) & ":" & Right("0" & Second(value), 2) & "Z"
End Function
%>
