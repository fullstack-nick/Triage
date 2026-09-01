<%
Const adCmdStoredProc = 4
Const adInteger = 3
Const adBigInt = 20
Const adVarChar = 200
Const adVarWChar = 202
Const adLongVarWChar = 203
Const adDBTimeStamp = 135
Const adBoolean = 11
Const adParamInput = 1

Function TriageOpenConnection()
    Dim connection
    Set connection = Server.CreateObject("ADODB.Connection")
    connection.CommandTimeout = 30
    connection.Open TriageAdoConnectionString()
    Set TriageOpenConnection = connection
End Function

Sub TriageAddParameter(ByRef command, ByVal parameterName, ByVal dataType, ByVal size, ByVal parameterValue)
    Dim parameter
    If size > 0 Then
        Set parameter = command.CreateParameter(parameterName, dataType, adParamInput, size, parameterValue)
    Else
        Set parameter = command.CreateParameter(parameterName, dataType, adParamInput, , parameterValue)
    End If
    command.Parameters.Append parameter
End Sub

Function TriageCommand(ByRef connection, ByVal procedureName)
    Dim command
    Set command = Server.CreateObject("ADODB.Command")
    Set command.ActiveConnection = connection
    command.CommandType = adCmdStoredProc
    command.CommandText = procedureName
    command.CommandTimeout = 30
    Set TriageCommand = command
End Function
%>
