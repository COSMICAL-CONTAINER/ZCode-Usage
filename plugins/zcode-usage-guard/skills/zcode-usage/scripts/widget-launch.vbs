' 悬浮窗启动器(插件 SessionStart hook 调用;相对自身定位,无需绝对路径)
' NoShowIfExists:已有悬浮窗在运行时静默退出(会话唤醒由 widget-launch.mjs 的唤醒文件完成),没有则静默拉起
Dim dir, shell
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\zcode-usage-widget.ps1"" -NoShowIfExists", 0, False
