Imports System
Imports System.Data
Imports System.Data.SqlClient
Imports System.Web.UI
Imports System.Web.UI.WebControls

Partial Public Class Score
    Inherits Page

    Protected ReviewerNameHeader As Literal
    Protected CsrfField As HiddenField
    Protected ErrorPanel As Panel
    Protected ErrorMessage As Literal
    Protected StatusPanel As Panel
    Protected StatusMessage As Literal
    Protected AssignmentPanel As Panel
    Protected AbstractIdText As Literal
    Protected DueAtText As Literal
    Protected TitleText As Literal
    Protected TrackText As Literal
    Protected BodyText As Literal
    Protected ScoreInput As RadioButtonList
    Protected CommentLabel As Label
    Protected CommentInput As TextBox
    Protected WithEvents SaveDraftButton As Button
    Protected WithEvents SubmitFinalButton As Button
    Protected WithEvents DeclareConflictButton As Button
    Protected ConflictConfirmation As Panel
    Protected WithEvents ConfirmConflictButton As Button
    Protected WithEvents CancelConflictButton As Button

    Private Property AssignmentId As Integer
        Get
            Return If(ViewState("AssignmentId") Is Nothing, 0, CInt(ViewState("AssignmentId")))
        End Get
        Set(value As Integer)
            ViewState("AssignmentId") = value
        End Set
    End Property

    Protected Overrides Sub OnInit(e As EventArgs)
        MyBase.OnInit(e)
        ViewStateUserKey = Session.SessionID
    End Sub

    Protected Sub Page_Load(sender As Object, e As EventArgs) Handles Me.Load
        If Convert.ToString(Session("ReviewerRole")) <> "Reviewer" OrElse Session("ReviewerUserId") Is Nothing Then
            Response.Redirect("dev-login.aspx", False)
            Context.ApplicationInstance.CompleteRequest()
            Return
        End If

        ReviewerNameHeader.Text = Server.HtmlEncode(Convert.ToString(Session("ReviewerDisplayName")))
        CsrfField.Value = Convert.ToString(Session("ReviewerCsrfToken"))

        If Not IsPostBack Then
            Dim requestedId As Integer
            If Not Integer.TryParse(Request.QueryString("id"), requestedId) OrElse requestedId < 1 Then requestedId = 1
            AssignmentId = requestedId
            LoadAssignment()
        End If
    End Sub

    Protected Sub SaveDraftButton_Click(sender As Object, e As EventArgs)
        SaveReview(False)
    End Sub

    Protected Sub SubmitFinalButton_Click(sender As Object, e As EventArgs)
        SaveReview(True)
    End Sub

    Protected Sub DeclareConflictButton_Click(sender As Object, e As EventArgs)
        If Not CsrfIsValid() Then
            ShowError("The request could not be verified. Refresh the page and try again.")
            Return
        End If
        ConflictConfirmation.Visible = True
    End Sub

    Protected Sub CancelConflictButton_Click(sender As Object, e As EventArgs)
        ConflictConfirmation.Visible = False
    End Sub

    Protected Sub ConfirmConflictButton_Click(sender As Object, e As EventArgs)
        If Not CsrfIsValid() Then
            ShowError("The request could not be verified. Refresh the page and try again.")
            Return
        End If

        Try
            Using connection As New SqlConnection(ConnectionString())
                Using command As New SqlCommand("dbo.usp_ReviewAssignment_ConflictDeclare", connection)
                    command.CommandType = CommandType.StoredProcedure
                    command.Parameters.Add("@AssignmentId", SqlDbType.Int).Value = AssignmentId
                    command.Parameters.Add("@ReviewerUserId", SqlDbType.Int).Value = CInt(Session("ReviewerUserId"))
                    connection.Open()
                    command.ExecuteNonQuery()
                End Using
            End Using
            AssignmentPanel.Visible = False
            ShowStatus("Conflict recorded. This assignment is now closed.")
        Catch ex As SqlException
            ShowError("The assignment could not be changed. It may already be closed.")
        End Try
    End Sub

    Private Sub SaveReview(isFinal As Boolean)
        ErrorPanel.Visible = False
        StatusPanel.Visible = False

        If Not CsrfIsValid() Then
            ShowError("The request could not be verified. Refresh the page and try again.")
            Return
        End If

        Dim scoreValue As Byte
        Dim hasScore = Byte.TryParse(ScoreInput.SelectedValue, scoreValue) AndAlso scoreValue >= 1 AndAlso scoreValue <= 5
        If isFinal AndAlso Not hasScore Then
            ShowError("Choose a score from 1 through 5 before submitting a final evaluation.")
            Return
        End If
        If CommentInput.Text.Length > 2000 Then
            ShowError("The private comment must be 2,000 characters or fewer.")
            Return
        End If

        Try
            Using connection As New SqlConnection(ConnectionString())
                Using command As New SqlCommand("dbo.usp_Review_Save", connection)
                    command.CommandType = CommandType.StoredProcedure
                    command.Parameters.Add("@AssignmentId", SqlDbType.Int).Value = AssignmentId
                    command.Parameters.Add("@ReviewerUserId", SqlDbType.Int).Value = CInt(Session("ReviewerUserId"))
                    Dim scoreParameter = command.Parameters.Add("@Score", SqlDbType.TinyInt)
                    scoreParameter.Value = If(hasScore, CType(scoreValue, Object), DBNull.Value)
                    command.Parameters.Add("@Comment", SqlDbType.NVarChar, 2000).Value = If(String.IsNullOrWhiteSpace(CommentInput.Text), CType(DBNull.Value, Object), CommentInput.Text)
                    command.Parameters.Add("@IsFinal", SqlDbType.Bit).Value = isFinal
                    connection.Open()
                    command.ExecuteNonQuery()
                End Using
            End Using
            ShowStatus(If(isFinal, "Final evaluation submitted.", "Draft saved."))
            LoadAssignment()
        Catch ex As SqlException
            ShowError("The evaluation could not be saved. It may have been changed in another request.")
        End Try
    End Sub

    Private Sub LoadAssignment()
        AssignmentPanel.Visible = False
        Using connection As New SqlConnection(ConnectionString())
            Using command As New SqlCommand("dbo.usp_ReviewAssignment_Get", connection)
                command.CommandType = CommandType.StoredProcedure
                command.Parameters.Add("@AssignmentId", SqlDbType.Int).Value = AssignmentId
                command.Parameters.Add("@ReviewerUserId", SqlDbType.Int).Value = CInt(Session("ReviewerUserId"))
                connection.Open()
                Using reader = command.ExecuteReader(CommandBehavior.SingleRow)
                    If Not reader.Read() Then
                        ShowError("The assignment was not found.")
                        Return
                    End If

                    AbstractIdText.Text = Server.HtmlEncode(Convert.ToString(reader("AbstractId")))
                    TitleText.Text = Server.HtmlEncode(Convert.ToString(reader("Title")))
                    TrackText.Text = Server.HtmlEncode(Convert.ToString(reader("Track")))
                    BodyText.Text = Server.HtmlEncode(Convert.ToString(reader("Body")))
                    DueAtText.Text = CDate(reader("DueAtUtc")).ToString("yyyy-MM-dd HH:mm")
                    If reader("Score") IsNot DBNull.Value Then ScoreInput.SelectedValue = Convert.ToString(reader("Score"))
                    CommentInput.Text = If(reader("Comment") Is DBNull.Value, String.Empty, Convert.ToString(reader("Comment")))
                    Dim isFinal = reader("IsFinal") IsNot DBNull.Value AndAlso CBool(reader("IsFinal"))
                    SaveDraftButton.Enabled = Not isFinal
                    SubmitFinalButton.Enabled = Not isFinal
                    DeclareConflictButton.Enabled = Not isFinal
                    ScoreInput.Enabled = Not isFinal
                    CommentInput.Enabled = Not isFinal
                    AssignmentPanel.Visible = True
                End Using
            End Using
        End Using
    End Sub

    Private Function CsrfIsValid() As Boolean
        Dim expected = Convert.ToString(Session("ReviewerCsrfToken"))
        Return expected.Length = 64 AndAlso String.Equals(expected, CsrfField.Value, StringComparison.Ordinal)
    End Function

    Private Shared Function ConnectionString() As String
        Return Environment.GetEnvironmentVariable("TRIAGE_DB_CONNECTION")
    End Function

    Private Sub ShowError(message As String)
        ErrorMessage.Text = Server.HtmlEncode(message)
        ErrorPanel.Visible = True
    End Sub

    Private Sub ShowStatus(message As String)
        StatusMessage.Text = Server.HtmlEncode(message)
        StatusPanel.Visible = True
    End Sub
End Class
