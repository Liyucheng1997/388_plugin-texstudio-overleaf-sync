%SCRIPT
// Overleaf 同步: save all files, then open the GitHub/Overleaf sync window.
// Installed by install.ps1, which fills in the script path below.
var script = "__SCRIPT_PATH__";
app.fileSaveAll();
var file = "";
try {
    var doc = documentManager.masterDocument;
    if (!doc) doc = editor.document().getRootDocument();
    if (doc) file = doc.fileName;
} catch (e) {}
if (!file) file = app.getCurrentFileName();
if (!file) {
    alert("请先保存当前文档，再同步。");
} else {
    // Hex-encode the path: TeXstudio expands characters such as % ? @ in commands.
    var hex = "";
    for (var i = 0; i < file.length; i++) hex += ("000" + file.charCodeAt(i).toString(16)).slice(-4);
    var proc = system("powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -PathHex " + hex);
    if (!proc) alert("TeXstudio 没有允许这个宏运行外部命令，同步已取消。");
}
