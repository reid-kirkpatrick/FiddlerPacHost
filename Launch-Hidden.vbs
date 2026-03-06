' Launch-Hidden.vbs — Launches Watch-Fiddler.ps1 from the same directory
' with no visible window.  All arguments are forwarded to the script.
'
' Used by the FiddlerPacWatcher scheduled task so that no console window
' is ever created (WScript.Shell.Run with window-style 0).

Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & dir & "\Watch-Fiddler.ps1"""

For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If InStr(arg, " ") > 0 Then
        cmd = cmd & " """ & arg & """"
    Else
        cmd = cmd & " " & arg
    End If
Next

CreateObject("WScript.Shell").Run cmd, 0, True
