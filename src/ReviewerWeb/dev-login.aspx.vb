Imports System
Imports System.Data
Imports System.Data.SqlClient
Imports System.Security.Cryptography
Imports System.Web.UI
Imports System.Web.UI.WebControls

Partial Public Class DevLogin
    Inherits Page

    Protected ErrorPanel As Panel
    Protected ErrorMessage As Literal
    Protected CsrfField As HiddenField
    Protected PasswordInput As TextBox
    Protected PasswordLabel As Label
    Protected WithEvents LoginButton As Button

    Protected Overrides Sub OnInit(e As EventArgs)
        MyBase.OnInit(e)
        ViewStateUserKey = Session.SessionID
        EnsureCsrfToken()
    End Sub

    Protected Sub Page_Load(sender As Object, e As EventArgs) Handles Me.Load
        CsrfField.Value = Convert.ToString(Session("ReviewerCsrfToken"))
    End Sub

    Protected Sub LoginButton_Click(sender As Object, e As EventArgs)
        ErrorPanel.Visible = False

        If Not CsrfIsValid() Then
            ShowError("The request could not be verified. Refresh the page and try again.")
            Return
        End If

        Dim expectedPassword = Environment.GetEnvironmentVariable("TRIAGE_REVIEWER_PASSWORD")
        If String.IsNullOrEmpty(expectedPassword) OrElse Not String.Equals(PasswordInput.Text, expectedPassword, StringComparison.Ordinal) Then
            ShowError("The development password was not accepted. Read the generated local settings file and try again.")
            Return
        End If

        Dim connectionString = Environment.GetEnvironmentVariable("TRIAGE_DB_CONNECTION")
        Using connection As New SqlConnection(connectionString)
            Using command As New SqlCommand("dbo.usp_DevelopmentSession_Start", connection)
                command.CommandType = CommandType.StoredProcedure
                command.Parameters.Add("@Email", SqlDbType.NVarChar, 254).Value = "reviewer001@example.test"
                command.Parameters.Add("@ExpectedRole", SqlDbType.VarChar, 16).Value = "Reviewer"
                connection.Open()
                Using reader = command.ExecuteReader(CommandBehavior.SingleRow)
                    If Not reader.Read() Then
                        ShowError("The development reviewer account is unavailable.")
                        Return
                    End If

                    Session("ReviewerUserId") = reader.GetInt32(reader.GetOrdinal("UserId"))
                    Session("ReviewerRole") = reader.GetString(reader.GetOrdinal("UserRole"))
                    Session("ReviewerDisplayName") = reader.GetString(reader.GetOrdinal("DisplayName"))
                End Using
            End Using
        End Using

        Response.Redirect("score.aspx?id=1", False)
        Context.ApplicationInstance.CompleteRequest()
    End Sub

    Private Sub EnsureCsrfToken()
        If Session("ReviewerCsrfToken") Is Nothing Then
            Dim bytes(31) As Byte
            Using generator = RandomNumberGenerator.Create()
                generator.GetBytes(bytes)
            End Using
            Session("ReviewerCsrfToken") = BitConverter.ToString(bytes).Replace("-", String.Empty)
        End If
    End Sub

    Private Function CsrfIsValid() As Boolean
        Dim expected = Convert.ToString(Session("ReviewerCsrfToken"))
        Dim supplied = Convert.ToString(Request.Form(CsrfField.UniqueID))
        Return expected.Length = 64 AndAlso supplied.Length = 64 AndAlso String.Equals(expected, supplied, StringComparison.Ordinal)
    End Function

    Private Sub ShowError(message As String)
        ErrorMessage.Text = Server.HtmlEncode(message)
        ErrorPanel.Visible = True
    End Sub
End Class
