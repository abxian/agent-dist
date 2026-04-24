# agent-dist — Agent / ScreenAgent 安装与自动更新分发仓库

两套独立的客户端 + 一键安装脚本,**双源**(GitHub + 国内 dufs)互备、互为回退。

| 产品 | 传输内容 | 默认安装目录 | Windows 服务名 |
|---|---|---|---|
| **Agent**       | 摄像头 + 麦克风 | `%ProgramData%\Agent`       | `RemoteAgent` |
| **ScreenAgent** | 屏幕录制        | `%ProgramData%\ScreenAgent` | `RemoteScreenAgent` |

两者**完全独立**,可以只装一个,也可以在同一台机器上**同时装两个**互不冲突。

---

## 📁 仓库内容

### Agent 相关
| 文件 | 说明 |
|---|---|
| `install-agent.ps1`    | Agent 客户端脚本,默认 `-Source auto`(GitHub 优先) |
| `install-agent-cn.ps1` | Agent 客户端脚本,默认 `-Source cn`(国内 dufs 优先) |
| `version.json`         | Agent 版本清单(版本号 + 每个文件的 SHA256) |
| `Agent.exe`            | Agent 主程序(摄像头/麦克风) |
| `agent.ini`            | 默认配置,`Host=110.42.44.89 Port=9999` |

### ScreenAgent 相关
| 文件 | 说明 |
|---|---|
| `install-screenagent.ps1`    | ScreenAgent 客户端脚本,默认 `-Source auto`(GitHub 优先) |
| `install-screenagent-cn.ps1` | ScreenAgent 客户端脚本,默认 `-Source cn`(国内 dufs 优先) |
| `version-screen.json`        | ScreenAgent 版本清单(独立于 `version.json`) |
| `ScreenAgent.exe`            | ScreenAgent 主程序(屏幕) |
| `screenagent.ini`            | 默认配置,`Host=110.42.44.89 Port=9999` |

### 公共 / 工具
| 文件 | 说明 |
|---|---|
| `opencv_world4100.dll` | OpenCV 运行时(~62 MB),两个 Agent 共用同一份 DLL |
| `gen-version.ps1`      | 发布工具:重算 SHA256 并生成清单 JSON |
| `agent-status.ps1`     | 客户端现状巡检脚本(可选) |

**两个分发源始终保持同步:**
- GitHub:`https://raw.githubusercontent.com/abxian/agent-dist/main/`
- 国内 dufs:`http://114.80.36.225:15667/6/`

---

## 🚀 客户端一键命令

> 首次安装与日后升级**是同一条命令**,无需任何交互。脚本自己比对清单里的 SHA256,只下载变更过的文件,停旧 exe → 替换 → 重新启动。

### Agent(摄像头 / 麦克风)

国内源(推荐):
```powershell
iex (irm http://114.80.36.225:15667/6/install-agent-cn.ps1)
```
GitHub 源:
```powershell
iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/install-agent.ps1)
```

默认连接 `110.42.44.89:9999`,装完不用带参数,直接可用。

### ScreenAgent(屏幕录制)

国内源(推荐):
```powershell
iex (irm http://114.80.36.225:15667/6/install-screenagent-cn.ps1)
```
GitHub 源:
```powershell
iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/install-screenagent.ps1)
```

默认同样连接 `110.42.44.89:9999`,装完不用带参数,直接可用。

### 两个一起装(同一台机器)

```powershell
iex (irm http://114.80.36.225:15667/6/install-agent-cn.ps1)
iex (irm http://114.80.36.225:15667/6/install-screenagent-cn.ps1)
```
分别进入 `%ProgramData%\Agent\` 和 `%ProgramData%\ScreenAgent\`,各自走独立服务,Server 端列表里会出现两个连接。

---

## ⚙️ 指定非默认服务器地址(可选)

**默认 ini 已写死 `110.42.44.89:9999`,绝大多数情况不用管这段。** 只有需要连到自己的服务器时才用。

### 首次安装时通过参数写入 ini

`iex (irm ...)` 不支持带参数,所以要么**先下载再带参数执行**,要么**用环境变量**传递。

**方案 1:下载到临时目录再跑**

```powershell
iwr http://114.80.36.225:15667/6/install-screenagent-cn.ps1 -OutFile $env:TEMP\isa.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\isa.ps1 `
    -ServerIp 192.168.1.100 -ServerPort 9999 -ServerPassword mypwd
```

参数会被传给 `ScreenAgent.exe -install <ip> <port> <pwd>`,写进安装目录下的 ini。

Agent 版类似:
```powershell
iwr http://114.80.36.225:15667/6/install-agent-cn.ps1 -OutFile $env:TEMP\ia.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\ia.ps1 -InstallDir D:\Agent
```
> Agent 脚本目前不接受 `-ServerIp/-ServerPort`(Agent.exe 安装参数更少),需要改服务器的话用方案 2 直接改 `agent.ini`,或在仓库里改默认 `agent.ini` 后发一版。

**方案 2:装完后直接改 ini**

脚本安装完**会保留**本地已有的 ini(避免覆盖用户配置),所以:
```powershell
notepad %ProgramData%\ScreenAgent\screenagent.ini
# 改 Host=... Port=...,保存
ScreenAgent.exe -stop    # 或 sc stop RemoteScreenAgent
ScreenAgent.exe -start   # 或 sc start RemoteScreenAgent
```
下次升级(再跑 iex)**不会覆盖你改过的 ini**。

### 所有脚本可选参数

| 参数 | 默认 | Agent | ScreenAgent | 说明 |
|---|---|:-:|:-:|---|
| `-Source`         | `auto`/`cn`                    | ✅ | ✅ | `auto` / `github` / `cn` |
| `-InstallDir`     | `%ProgramData%\Agent` 或 `\ScreenAgent` | ✅ | ✅ | 安装目录 |
| `-ServerIp`       | —                              |    | ✅ | 首次安装时写入 ini 的 Host |
| `-ServerPort`     | —                              |    | ✅ | 首次安装时写入 ini 的 Port |
| `-ServerPassword` | —                              |    | ✅ | 首次安装时写入 ini 的 Password |
| `-GithubUser`     | `abxian`                       | ✅ | ✅ | 仓库用户名 |
| `-GithubRepo`     | `agent-dist`                   | ✅ | ✅ | 仓库名 |
| `-GithubBranch`   | `main`                         | ✅ | ✅ | 分支 |
| `-CnBase`         | `http://114.80.36.225:15667/6` | ✅ | ✅ | 国内源基地址 |
| `-Verbose`        | off                            | ✅ | ✅ | 打印详细日志 |

---

## 🔄 开机自动检查更新(可选)

在客户端机器上执行一次,以后每次开机静默自动升级:

**Agent:**
```powershell
schtasks /Create /SC ONSTART /TN AgentAutoUpdate /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"iex (irm http://114.80.36.225:15667/6/install-agent-cn.ps1)\"" /RU SYSTEM /F
```

**ScreenAgent:**
```powershell
schtasks /Create /SC ONSTART /TN ScreenAgentAutoUpdate /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"iex (irm http://114.80.36.225:15667/6/install-screenagent-cn.ps1)\"" /RU SYSTEM /F
```

取消:`schtasks /Delete /TN AgentAutoUpdate /F`(或 `ScreenAgentAutoUpdate`)。

> 注:Server 端本身也支持**推式热升级**(MSG_VERSION/CMD_UPDATE_PUSH 协议)。Server 对话框里 "Stage Update..." + "Auto" 勾上之后,新 Agent 一连上来就会被自动推最新 exe,无需等到下次开机。两个机制互补。

---

## 📦 发版流程(管理员侧)

### 一键发版(推荐)

仓库根目录有 `release.ps1`,一条命令跑完 Step 2~6:

```powershell
.\release.ps1 -Version 1.0.2
```

脚本会:
1. 自动把 `Agent.cpp` / `ScreenAgent.cpp` 里的 `#define AGENT_VERSION` 改成 `1.0.2`
2. 提示你在 VS 里 `生成 → 重新生成解决方案`,编好后回车继续
3. 把 `vs\bin\Release\` 下的 `Agent.exe` / `ScreenAgent.exe` / `opencv_world4100.dll` + `screenagent.ini` 拷贝到 `agent-dist\`
4. 同时生成 `version.json`(Agent 清单)和 `version-screen.json`(ScreenAgent 清单)
5. `agent-dist` 提交 + 打 tag `v1.0.2` + 推 GitHub
6. `curl --upload-file` 批量上传到 dufs

可选开关:
| 开关 | 用途 |
|---|---|
| `-SkipBump`  | 已手动改过 `AGENT_VERSION` 就加上 |
| `-SkipBuild` | 已手动编译好了就加上 |
| `-SkipGit`   | 只推 dufs,不碰 GitHub |
| `-SkipDufs`  | 只推 GitHub,不碰 dufs |

### 手工发版(作为参考)

```powershell
cd C:\Users\fucku\Desktop\cam\agent-dist

# Agent 清单
powershell -ExecutionPolicy Bypass -File .\gen-version.ps1 -Version 1.0.2

# ScreenAgent 清单(独立文件)
powershell -ExecutionPolicy Bypass -File .\gen-version.ps1 -Version 1.0.2 `
    -Files @('ScreenAgent.exe','screenagent.ini','opencv_world4100.dll') `
    -OutFile version-screen.json

# 推 GitHub
git add -A
git commit -m "v1.0.2"
git tag -a v1.0.2 -m "v1.0.2"
git push origin main --tags

# 推 dufs
$base = 'http://114.80.36.225:15667/6'
foreach ($f in 'Agent.exe','ScreenAgent.exe','opencv_world4100.dll',
               'agent.ini','screenagent.ini',
               'version.json','version-screen.json',
               'install-agent.ps1','install-agent-cn.ps1',
               'install-screenagent.ps1','install-screenagent-cn.ps1') {
    curl.exe -T $f "$base/$f"
}
```

---

## 🔍 客户端脚本工作流程

```
读取 -Source
   ↓ auto 时探测两源可达性
拉取 <base>/version.json           (Agent)
     <base>/version-screen.json    (ScreenAgent)
   ↓ 解析 version + files[].sha256
对比 installed.version + 本地文件 SHA256
   ↓ 不一致或缺失的文件才下载
停止 当前运行的同目录 exe          (优雅 -stop,超时兜底 Stop-Process)
下载 <base>/<file> → *.downloading → 原子改名替换
校验 SHA256(失败直接退出,不破坏现状)
写入 installed.version
首次安装:exe -install (可带 ip/port/pwd) 注册服务
启动 exe -start(隐藏窗口)
```

特性:
- **幂等**:已是最新就不下载、不重启,直接 "完成: 无需更新"。
- **保留用户 ini**:`agent.ini` / `screenagent.ini` 本地已存在就**不会**被下载覆盖。
- **断点安全**:用 `*.downloading` 临时文件,完成才替换。
- **双源容错**:首选源拉某文件失败自动切到备用源重试。
- **SHA256 校验**:与清单不符立即报错退出,不会用损坏文件替换。

---

## 🛠 常见问题

**Q: 客户端报 "无法下载 xxx"?**
A: 两个源都不通。检查联网,或显式指定 `-Source github` / `-Source cn`。

**Q: 想强制重装?**
A: 删 `installed.version` 后重跑 iex。彻底重装就删整个安装目录(`%ProgramData%\Agent\` 或 `\ScreenAgent\`)。注意 ScreenAgent 服务需先 `sc stop RemoteScreenAgent && sc delete RemoteScreenAgent`。

**Q: 一台机器同时装 Agent 和 ScreenAgent,会冲突吗?**
A: 不会。二进制、安装目录、服务名、清单文件**完全隔离**。

**Q: `opencv_world4100.dll` 推 GitHub 警告 >50MB?**
A: 约 62MB,在 100MB 硬上限内,警告可忽略。如果以后超 100MB,改用 GitHub Releases 或启用 Git LFS。

**Q: PowerShell 执行策略受限?**
A: `iex (irm ...)` 不受执行策略限制。如果用 `-File` 形式,加 `-ExecutionPolicy Bypass`。

**Q: 怎么看客户端现在是什么版本?**
A:
```powershell
type %ProgramData%\Agent\installed.version
type %ProgramData%\ScreenAgent\installed.version
```

**Q: 改服务器地址后怎么刷新?**
A: 直接改对应 ini,然后重启服务:
```powershell
sc stop RemoteAgent && sc start RemoteAgent
sc stop RemoteScreenAgent && sc start RemoteScreenAgent
```
或 `Agent.exe -stop` / `-start`。ini 改动**无需重启机器**,只要重启服务即可。

---

## 📌 快速参考卡

| 场景 | 命令 |
|---|---|
| **装 Agent(国内)**         | `iex (irm http://114.80.36.225:15667/6/install-agent-cn.ps1)` |
| **装 ScreenAgent(国内)**   | `iex (irm http://114.80.36.225:15667/6/install-screenagent-cn.ps1)` |
| **两个都装**                 | 依次跑上面两条 |
| **装 Agent(GitHub)**       | `iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/install-agent.ps1)` |
| **装 ScreenAgent(GitHub)** | `iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/install-screenagent.ps1)` |
| **带参数首装 ScreenAgent**   | `iwr ...install-screenagent-cn.ps1 -OutFile $env:TEMP\isa.ps1; & $env:TEMP\isa.ps1 -ServerIp x.x.x.x -ServerPort 9999` |
| **一键发版**                 | `.\release.ps1 -Version 1.0.x` |
| **查 Agent 版本**            | `type %ProgramData%\Agent\installed.version` |
| **查 ScreenAgent 版本**      | `type %ProgramData%\ScreenAgent\installed.version` |
| **强制重装 Agent**           | 删 `%ProgramData%\Agent\installed.version` → 重跑 iex |
| **卸载 ScreenAgent**         | `sc stop RemoteScreenAgent; sc delete RemoteScreenAgent; rd /s /q %ProgramData%\ScreenAgent` |
