# TeXstudio → GitHub → Overleaf 一键同步

在 TeXstudio 里按 **Ctrl+Alt+G**，弹出同步窗口：勾选要提交的文件、写一句更新说明、确认版本号，点「同步到 GitHub」。
脚本会自动：

1. 保存所有打开的文件；
2. 只提交你勾选的文件（编译产物、压缩包等默认不勾选）；
3. 先合并 GitHub 上的新提交（也就是老师在 Overleaf 上改的内容），再推送；
4. 打上版本号标签（v1.0 → v1.1 → …，可手动改，或点「大版本 +1」）；
5. 推送到 GitHub，提示你去 Overleaf 拉取。

```
TeXstudio ──Ctrl+Alt+G──▶ 本地 Git（版本号 v1.x）──push──▶ GitHub ◀──Pull / Push──▶ Overleaf（老师）
```

## 安装

先**关闭 TeXstudio**（它退出时会覆盖宏文件），然后在本目录运行：

```bash
powershell -ExecutionPolicy Bypass -File install.ps1
```

- 想换快捷键：`install.ps1 -Shortcut "Ctrl+Shift+F12"`
- 卸载：`install.ps1 -Uninstall`
- 更新：改完 `src\OverleafSync.ps1` 后重新运行安装即可。

启动 TeXstudio 后，菜单「宏」里会出现「Overleaf 同步」。**第一次运行**时 TeXstudio 会问是否信任这个脚本，选
`Yes, allow all calls it will ever make`。
想要工具栏按钮：选项 → 配置 TeXstudio → 工具栏 → 把「宏 → Overleaf 同步」拖到自定义工具栏。

需要：Git for Windows；新建 GitHub 仓库时用到 GitHub CLI（`gh auth login` 已登录）。

## 第一次关联一篇论文

1. 打开论文的主 `.tex`，按 Ctrl+Alt+G。
   - 文件夹还不是 Git 仓库时，会提示初始化：自动生成 `.gitignore`（排除 `.aux/.log/…` 和主文档编译出的 PDF），并用 `gh` 新建一个**私有**仓库（也可以粘贴已有仓库地址）。
   - 已经是 Git 仓库（例如 `F:\latex\10_IEEE_...`）就直接进入同步窗口，沿用已有的版本号。
2. 第一次同步，把内容推上 GitHub。
3. 在 Overleaf：**New Project → Import from GitHub**，选这个仓库。
   Overleaf 不能把**已存在的** Overleaf 项目关联到已有仓库，只能从仓库新建项目（或从 Overleaf 项目新建仓库）。
4. 把老师加为这个 Overleaf 项目的协作者（Share）。
5. 回到同步窗口点「Overleaf」按钮，粘贴项目链接；以后同步完会提示一键打开它。

## 日常使用

| 场景 | 你要做的 |
| --- | --- |
| 我改完一部分，想让老师看到 | Ctrl+Alt+G → 写说明 → 同步。然后在 Overleaf：Menu → GitHub → **Pull GitHub changes into Overleaf** |
| 老师在 Overleaf 上改了 | 老师（或你）在 Overleaf：Menu → GitHub → **Push Overleaf changes to GitHub**。之后你在 TeXstudio 同步时会自动合并下来，TeXstudio 提示文件已改动时选重新加载 |
| 双方改了同一处 | 同步窗口会列出冲突文件，文件里用 `<<<<<<<` / `=======` / `>>>>>>>` 标出两个版本。保留正确内容、删掉标记行、保存，再点同步完成合并；也可以点「放弃合并」 |
| 想看某个版本改了什么 | 双击文件看改动；「版本历史」→ 在 GitHub 查看 / 与当前版本对比 |
| 想回到旧版本 | 「版本历史」→ 选版本 →「恢复到此版本」。不删任何历史，恢复后的内容作为新修改，同步后成为一个新版本（如 v2.1 = v1.0 的内容） |
| 某个新文件永远不想上传 | 选中它 →「忽略所选」（写入 `.gitignore`） |

## 需要知道的限制

- **Overleaf 的 GitHub 同步是付费功能**（个人订阅、团队订阅或学校的 Overleaf Commons 授权都可以；项目所有者有权限即可）。免费账号没有这个菜单。
- **Overleaf 不会自动拉取**：推送后要在 Overleaf 里点一次「Pull GitHub changes into Overleaf」，这一步 Overleaf 没有开放接口，脚本只能帮你打开项目页面。
- Overleaf 只同步仓库的默认分支（main/master），单个文件不能超过 50 MB；超过的文件同步前会提醒。
- Overleaf 从 GitHub 拉取时，被改动文件上的批注 / Track Changes 可能丢失。和老师约定：他在 Overleaf 上评论时你先别推同一个文件，或者请他直接改正文。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `src/OverleafSync.ps1` | 同步逻辑和窗口（PowerShell 5.1 + WinForms，无需额外安装） |
| `src/macro.js` | TeXstudio 宏模板：保存全部文件，找到主文档，启动同步窗口 |
| `install.ps1` | 把脚本装到 `%APPDATA%\texstudio\overleaf-sync\`，写入宏文件 |
| `tests/run-tests.ps1` | 端到端测试：用本地裸仓库模拟 GitHub、另一个克隆模拟 Overleaf |

命令行用法（不弹窗口）：

```bash
powershell -File src\OverleafSync.ps1 -Path F:\paper\main.tex -NoGui -Message "修改引言"
```

出问题时看日志：`%LOCALAPPDATA%\OverleafSync\sync.log`（记录了每条 git 命令和输出）。
