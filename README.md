# agent-dist

Agent 分发仓库 — 存放 `Agent.exe` / `agent.ini` / `opencv_world4100.dll` 以及 `version.json`。
安装脚本会从 GitHub raw 或国内源读取 `version.json`,依据 SHA256 判断是否需要更新。

## 目录内容

```
Agent.exe
agent.ini
opencv_world4100.dll
version.json        # 版本清单
gen-version.ps1     # 生成/刷新 version.json
```

## 发布新版本步骤

1. 把新的 `Agent.exe` / `agent.ini` / `opencv_world4100.dll` 覆盖到本目录。
2. 运行:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\gen-version.ps1 -Version 1.0.1
   ```
   这会重新计算 SHA256 并写入 `version.json`。
3. `git add . && git commit -m "release 1.0.1" && git push`。
4. 国内源 `http://114.80.36.225:15667/6/` 同步同样四个文件即可。

## 客户端使用

```powershell
# 自动选择可达源(GitHub 优先, 否则回退国内)
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1

# 强制 GitHub
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Source github

# 强制国内源
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Source cn

# 指定安装目录
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -InstallDir "C:\Agent"
```

脚本无交互:检测版本 → 下载变更文件 → 校验 SHA256 → 停止旧进程 → 替换 → 启动。
以后只需重复执行同一条命令即可自动升级。
