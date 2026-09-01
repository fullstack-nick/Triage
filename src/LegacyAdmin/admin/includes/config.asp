<%
Function TriageEnvironmentValue(ByVal valueName)
    Dim shell, processEnvironment
    Set shell = Server.CreateObject("WScript.Shell")
    Set processEnvironment = shell.Environment("PROCESS")
    TriageEnvironmentValue = CStr(processEnvironment.Item(valueName))
    Set processEnvironment = Nothing
    Set shell = Nothing
End Function

Function TriageAdoConnectionString()
    TriageAdoConnectionString = TriageEnvironmentValue("TRIAGE_DB_CONNECTION_ADO")
End Function

Function TriageNotificationApiUrl()
    Dim configuredUrl
    configuredUrl = TriageEnvironmentValue("TRIAGE_NOTIFICATION_API_URL")
    If Len(configuredUrl) = 0 Then configuredUrl = "http://127.0.0.1:5071/api/review-reminders"
    TriageNotificationApiUrl = configuredUrl
End Function
%>
