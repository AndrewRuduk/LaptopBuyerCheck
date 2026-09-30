Option Explicit
Dim shell, fs, root, script, command, app, arguments
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
script = fs.BuildPath(root, "Check-Laptop.ps1")
arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & script & Chr(34)
Set app = CreateObject("Shell.Application")
On Error Resume Next
app.ShellExecute "powershell.exe", arguments, root, "runas", 0
If Err.Number <> 0 Then
    Err.Clear
    command = "powershell.exe " & arguments
    shell.Run command, 0, False
End If
On Error GoTo 0
