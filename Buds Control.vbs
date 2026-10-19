' Starts the Buds Air7 Pro control window without a console window.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "\buds-app.ps1""", 0, False
