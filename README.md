# agent-dist — Agent 安装 / 自动更新分发仓库

存放 `Agent.exe` / `agent.ini` / `opencv_world4100.dll` 以及版本清单 `version.json`,
配套 `install-agent.ps1` 客户端脚本可一键安装与自动升级,**双源**(GitHub + 国内 dufs)互备。

---

## 📁 仓库内容

| 文件 | 说明 |
|---|---|
| `install-agent.ps1` | 客户端安装/更新脚本(无交互,自动检测更新) |
| `gen-version.ps1`   | 发布工具:重新计算 SHA256 并生成 `version.json` |
| `version.json`      | 版本清单(版本号 + 每个文件的 SHA256) |
| `Agent.exe`         | Agent 主程序 |
| `agent.ini`         | 配置文件 |
| `opencv_world4100.dll` | OpenCV 运行时(~62 MB) |

**两个分发源始终保持同步:**
- GitHub:`https://raw.githubusercontent.com/abxian/agent-dist/main/`
- 国内 dufs:`http://114.80.36.225:15667/6/`

---

## 🚀 客户端安装 / 升级(一条命令)

> **首次安装与日后升级是同一条命令,无需任何选择。** 脚本自己比对 `version.json` 的 SHA256,只下载变更过的文件,停掉旧 `Agent.exe` → 替换 → 重新启动。

### 推荐:最短 `iex` 一键

国内源:
```powershell
iex (irm http://114.80.36.225:15667/6/install-agent.ps1)
```

GitHub 源:
```powershell
iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/install-agent.ps1)
```

### 完整命令(等价,但显式落盘)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr http://114.80.36.225:15667/6/install-agent.ps1 -UseBasicParsing -OutFile $env:TEMP\install-agent.ps1; & $env:TEMP\install-agent.ps1"
```

### `install-agent.ps1` 可选参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Source`     | `auto`               | `auto` / `github` / `cn`,`auto` 优先 GitHub,不通回退 dufs |
| `-InstallDir` | `C:\ProgramData\Agent` | 安装目录 |
| `-GithubUser` | `abxian`             | GitHub 用户名(改了仓库归属时调整) |
| `-GithubRepo` | `agent-dist`         | GitHub 仓库名 |
| `-GithubBranch` | `main`             | 分支 |
| `-CnBase`     | `http://114.80.36.225:15667/6` | 国内源基地址 |

例:强制走 GitHub 并装到 D 盘
```powershell
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Source github -InstallDir D:\Agent
```

### 开机自动检查更新(可选)

在客户端机器上执行一次,以后每次开机静默自动升级并启动 Agent:
```powershell
schtasks /Create /SC ONSTART /TN AgentAutoUpdate /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"iex (irm http://114.80.36.225:15667/6/install-agent.ps1)\"" /RU SYSTEM /F
```
取消任务:`schtasks /Delete /TN AgentAutoUpdate /F`

---

## 📦 发布新版本(管理员侧)

每次发布只做 3 件事:**换文件 → 生成清单 → 同步两个源**。

### 第 1 步 — 替换二进制
把新的 `Agent.exe` / `agent.ini` / `opencv_world4100.dll` 覆盖到本目录:
```
C:\Users\fucku\Desktop\cam\agent-dist\
```

### 第 2 步 — 生成新 version.json

```powershell
cd C:\Users\fucku\Desktop\cam\agent-dist
powershell -ExecutionPolicy Bypass -File .\gen-version.ps1 -Version 1.0.1
```
> 版本号自己递增,例如 `1.0.0 → 1.0.1 → 1.0.2`。脚本会自动重新计算三个文件的 SHA256。

### 第 3 步 — 同步到 GitHub + dufs

**GitHub(用 GitHub Desktop):**
1. 打开 GitHub Desktop,左侧会显示变更
2. 左下 Summary 填 `release 1.0.1` → 点 **Commit to main**
3. 右上点 **Push origin**

**国内 dufs(在 `agent-dist\` 目录运行 cmd 或 PowerShell):**
```powershell
curl.exe -T Agent.exe            http://114.80.36.225:15667/6/Agent.exe
curl.exe -T agent.ini            http://114.80.36.225:15667/6/agent.ini
curl.exe -T opencv_world4100.dll http://114.80.36.225:15667/6/opencv_world4100.dll
curl.exe -T version.json         http://114.80.36.225:15667/6/version.json
```
> 如果改动了 `install-agent.ps1`,再加一条:
> ```powershell
> curl.exe -T install-agent.ps1 http://114.80.36.225:15667/6/install-agent.ps1
> ```

完成。所有客户端下次执行 `iex` 命令时会自动升级到 1.0.1。

---

## 🔍 客户端脚本工作流程

```
读取 -Source 参数
   ↓ auto 时探测:GitHub raw 是否可达 → 否则用国内 dufs
拉取  <base>/version.json
   ↓ 解析 version + files[].sha256
对比  本地 installed.version 与 已存在文件的 SHA256
   ↓ 不一致或缺失的文件
停止  正在运行的同目录 Agent.exe
下载  <base>/<file> 到安装目录(原子替换)
校验  SHA256(失败则报错退出,不破坏现状)
写入  installed.version
启动  Agent.exe(隐藏窗口)
```

特性:
- **幂等**:已是最新就不下载、不重启,直接 "完成: 无需更新"。
- **断点安全**:下载用 `*.downloading` 临时文件,完成才替换。
- **双源容错**:首选源拉某文件失败时自动切到另一个源重试。
- **校验**:SHA256 与 `version.json` 不符立即退出,不会用损坏文件覆盖。

---

## 🛠 常见问题

**Q: 客户端报 "无法下载 xxx" 怎么办?**
A: 两个源都不通。检查机器联网,或临时改 `-Source github` / `-Source cn` 强制使用某一源。

**Q: 想强制重装(不论版本)?**
A: 删除 `C:\ProgramData\Agent\installed.version` 后再跑一次 `iex` 命令。或直接删整个 `C:\ProgramData\Agent\` 目录。

**Q: opencv_world4100.dll 推 GitHub 时警告 "larger than 50MB"?**
A: 当前 ~62MB,在 100MB 硬上限内,警告可忽略。如果以后超 100MB,改用 GitHub Releases 附件或启用 Git LFS。

**Q: dufs 上传命令报 SSL/HTTPS 错误?**
A: dufs 走 `http://`,不是 `https://`,确认 URL 协议正确。

**Q: 客户端 PowerShell 执行策略受限?**
A: `iex (irm ...)` 不受执行策略限制(因为脚本是字符串而非文件)。如果用 `-File` 形式调用,加 `-ExecutionPolicy Bypass`。

**Q: 怎么看客户端当前装的什么版本?**
A: `Get-Content C:\ProgramData\Agent\installed.version`

---

## 📌 快速参考卡

| 场景 | 命令 |
|---|---|
| **客户端首装/升级** | `iex (irm http://114.80.36.225:15667/6/install-agent.ps1)` |
| **管理端生成清单** | `powershell -ExecutionPolicy Bypass -File .\gen-version.ps1 -Version 1.0.x` |
| **管理端推 dufs** | `curl.exe -T <文件> http://114.80.36.225:15667/6/<文件>` |
| **管理端推 GitHub** | GitHub Desktop → Commit to main → Push origin |
| **客户端查版本** | `type C:\ProgramData\Agent\installed.version` |
| **客户端强制重装** | 删 `C:\ProgramData\Agent\installed.version` → 重跑 iex |
