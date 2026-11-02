# Ray–Isaac–Deploy v1.1.1 完整部署与使用手册

**适用范围**：Windows 控制机 + A800 Ray Head + RTX 4090 Ray Worker / Isaac Sim 可视化；Ubuntu 22.04 容器云主机，无 `/dev/net/tun`、无 VPN，采用 SSH 双向端口转发。  
**文档基准**：2026-10-27；GitHub `CornerOfSkyline/ray-isaac-deploy`；Windows 修复分支 `fix/windows-controller-v1.1.1`，提交 `de372f8`。  
**验证说明**：本项目的 Windows `status`、Ray 双节点查询、被动检查、noVNC 安全收敛、Xvnc 定向恢复已在实际环境验证；新机器上的独立 Ray 集群自动引导**尚未实现**。凡涉及新机器首次安装、服务停止或启动的步骤，均应先检查适用前提。

> **最重要的安全规则**：已有任务运行时，禁止使用 `stop-all.ps1`、全栈 `start-all.ps1`、`stop-cluster`、`ray stop` 或整套 `stop-visualization.sh` 作为日常修复手段。先只读检查进程、端口、管理 PID 记录和训练状态，再针对缺失的单一组件操作。`-Action verify -Mode active -Force` 会提交 GPU 任务，不属于普通健康检查。

---

## 1. 先读：常用操作速查

所有 Windows 命令均默认在**仓库根目录**执行，例如 `D:\workspace\isaacsim_ws\ray-isaac-deploy`。真正的入口是 `windows\deploy.ps1`，不是根目录下的 `deploy.ps1`。

### 1.1 日常开机 / 接管已经运行的集群（推荐）

```powershell
cd D:\workspace\isaacsim_ws\ray-isaac-deploy

# 先看版本，必须包含已修复的 v1.1.1 提交
git rev-parse --short HEAD

# 只读：远程 SSH、Ray、GPU、可视化状态
.\windows\deploy.ps1 -Action status
Write-Host "Status ExitCode=$LASTEXITCODE"

# 已有可视化服务运行时，只负责建立 Windows→4090 的 SSH 隧道并打开网页
.\windows\deploy.ps1 -Action open-viewer

# 此时再做被动验收（包含本地 16006 隧道检查）
.\windows\deploy.ps1 -Action verify -Mode passive
Write-Host "Verify ExitCode=$LASTEXITCODE"
```

浏览器地址：`http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote`。这里 `16006` 是 **Windows 本地**监听端口，不是 4090 的公网端口。

### 1.2 现有环境的已知正常值

| 检查 | 基线值 | 含义 |
|---|---|---|
| SSH A800 / 4090 | PASS / PASS | Windows 分别可通过 SSH 控制两个容器 |
| Ray 节点 | 2 Alive | A800 Head + 4090 Worker |
| Ray 声明 GPU | 8 + 1 | A800 声明 8，4090 **声明 1**；并非两台物理 GPU 数的总和 |
| 4090 物理 GPU | 4 张 | 4090 另外的资源留给 Isaac Sim 等用途；不能将 Ray 声明资源当作物理数量 |
| Isaac Sim | TCP 49100 | WebRTC signaling 监听，不等于视频流已成功 |
| Xvnc | TCP 5901，回环 | `127.0.0.1:5901` / `[::1]:5901` |
| noVNC | TCP 6006，回环 | `127.0.0.1:6006`，转发到 5901 |
| CDP | TCP 9222，回环 | WebRTC Electron 客户端调试接口；没有客户端时端口不存在 |
| 视频 | UDP 47998 | Isaac Sim 与本机 WebRTC Client 之间，留在 4090 容器内 |
| Windows 浏览器隧道 | 127.0.0.1:16006 | SSH `-L` 至远程 `127.0.0.1:6006` |

**退出码解释**：`status` 为 0 表示其检查范围内未标记故障；4 代表检测到缺失的可视化端口。`verify -Mode passive` 为 0 表示检查通过；1 可表示端口或本地隧道未通过。不要把非零退出码一概解读为 Ray 停机：按逐项输出判断。

### 1.3 两条最安全的远端只读命令

```powershell
# 检查 4090 上重要监听；在 Windows 本地过滤，避免远程 zsh 引号/通配符问题
ssh -T -p 46602 zjf@180.97.68.228 'ss -ltnp' |
    Select-String ':49100|:5901|:6006|:9222'

# 查看现有进程；不会重启或终止任何服务
ssh -T -p 46602 zjf@180.97.68.228 `
    'pgrep -af "kit/kit|Xvnc|websockify|isaacsim-webrtc" || true'
```

---

## 2. 系统架构与启动依赖

```text
Windows 10/11（PowerShell、Python、OpenSSH、浏览器）
  │
  ├── SSH 控制 ──> A800（Ray Head, 127.0.0.2, GCS :6379）
  │                 ║
  │                 ║ 经双方既有 SSH -L 隧道互通 Ray RPC/GCS
  │                 ║
  ├── SSH 控制 ──> 4090（Ray Worker, 127.0.0.3, Ray 声明 GPU:1）
  │                    ├── Isaac Sim Kit ── TCP 49100 + UDP 47998
  │                    ├── WebRTC Electron Client ── CDP 9222, DISPLAY=:1
  │                    ├── TigerVNC Xvnc ── DISPLAY=:1 / TCP 5901
  │                    └── websockify + noVNC ── TCP 6006 → 5901
  │
  └── Windows SSH -L 127.0.0.1:16006 → 4090 127.0.0.1:6006
          └── 浏览器访问 noVNC，显示 WebRTC Client 内的 Isaac Sim 视频
```

### 2.1 两个互相独立的系统

- **Ray 计算链路**：A800/4090 SSH 双向隧道 → Ray Head → Ray Worker → 实际调度到 4090 GPU 的 Ray 任务。Ray 是否正常应通过节点、资源和（经授权的）真实任务分别确认。
- **Isaac Sim 可视化链路**：Isaac Sim Kit → 4090 本机 WebRTC Client → Xvnc → websockify/noVNC → Windows SSH 隧道 → 浏览器。即使 Ray 正常，这条链路也可以部分中断；反之亦然。

### 2.2 适用环境及关键假设

当前已验证配置中：A800 作为 Head；RTX 4090 作为 Worker，并承载 Isaac Sim。Ubuntu 22.04，Python 3.10、Ray 固定 `2.40.0`。4090 的 Isaac Sim 版本以配置基线 `6.2.0-rc.14` 为准（界面中可能显示 6.2.0）。GPU 驱动、Vulkan、NVENC 必须与实际 Isaac Sim 构建匹配，不建议直接复制某个版本号后假设适用于新机器。

在容器中，不使用 TUN/VPN，也不依赖容器间公网直接互通；双方通过 SSH 端口转发实现 Ray 所需连接。容器内 `127.0.0.2`/`127.0.0.3` 是各自的回环地址，不能从这两个 IP 推断物理服务器地址。

---

## 3. 新 Windows 控制机器：从零配置

### 3.1 软件准备

安装或确认以下工具：Git for Windows、Windows PowerShell 5.1 或 PowerShell 7、Windows OpenSSH Client、Python 3.10+（Conda/Miniforge 可以）、现代浏览器。不要依赖 WindowsApps 的无效 `python3.exe` 占位别名。

```powershell
$PSVersionTable.PSVersion
git --version
Get-Command ssh
ssh -V
python --version
python -c "import sys; print(sys.executable)"
python -m pip install --upgrade pyyaml jsonschema websockets
```

如果 `python` 命令未找到，请先激活 Miniforge/Conda 环境，或将真实解释器加入 PATH。`deploy.ps1` 已修复为通过 `sys.executable` 选择实际 Python 路径。

### 3.2 初始化 SSH 密钥（不会覆盖现有密钥）

```powershell
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$key = Join-Path $sshDir 'id_ed25519_ray_isaac'
if (-not (Test-Path $key)) {
    ssh-keygen -t ed25519 -f $key -C 'ray-isaac-windows'
}
Get-Content "$key.pub"
```

把**公钥**分别追加至两个远程用户的 `~/.ssh/authorized_keys`；此步骤由云平台控制台、已有可登录 SSH 通道或运维人员完成。绝不要把私钥上传到 GitHub 或放进项目配置。首次连接前，应通过可信渠道核对主机指纹。

在 `$env:USERPROFILE\.ssh\config` 中可设置便捷别名（现有服务器地址仅为本次基线；新实例必须替换）：

```sshconfig
Host ray-a800
    HostName 117.74.66.77
    Port 46885
    User zjf
    IdentityFile ~/.ssh/id_ed25519_ray_isaac
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host ray-4090
    HostName 180.97.68.228
    Port 46602
    User zjf
    IdentityFile ~/.ssh/id_ed25519_ray_isaac
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

验证：

```powershell
ssh -T ray-a800 'echo OK'
ssh -T ray-4090 'echo OK'
# 如果新建密钥尚未授权，需先在服务端追加该公钥，不能用关闭身份验证的方式绕过
```

### 3.3 克隆正确版本

截至本手册基准日期，PR #2 是 **Ready for Review、未合并 main**。因此在新 Windows 机器上，若需立即使用修复过的控制器，必须检出对应分支（未来若已合并，可改用 main）：

```powershell
cd D:\workspace\isaacsim_ws
git clone https://github.com/CornerOfSkyline/ray-isaac-deploy.git
cd .\ray-isaac-deploy
git fetch origin
git switch --track origin/fix/windows-controller-v1.1.1
# 若本地已有该分支，则 git switch fix/windows-controller-v1.1.1
git rev-parse --short HEAD
```

应包含 `de372f8` 或之后的兼容性修复版本。此私有仓库需要拥有访问权限的 GitHub 凭据；若无 Git 凭据，可由已有电脑以安全方式传输代码包。

### 3.4 Windows 自检

```powershell
python .\linux\common\config_bridge.py verified-20261025
# 输出 JSON 且末尾 valid: true 后，再检查控制器
.\windows\deploy.ps1 -Action configure
.\windows\deploy.ps1 -Action status
```

运行 PowerShell 回归测试：

```powershell
.\tests\powershell\deploy_regression_tests.ps1
# 期望 13 passed, 0 failed（此为本地逻辑测试，不等同远端联通测试）
```

如果 PowerShell 策略阻止脚本，优先使用当前进程范围内的策略，而不是更改全机设置：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 3.5 日常从 Windows 开启画面

先确保远端可视化进程已经运行（详见第 6 节）。然后：

```powershell
.\windows\deploy.ps1 -Action open-viewer
.\windows\deploy.ps1 -Action verify -Mode passive
```

如果需要不用脚本、直接前台创建隧道，在**单独 PowerShell 窗口**执行：

```powershell
ssh -N -T -p 46602 `
  -L 127.0.0.1:16006:127.0.0.1:6006 `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=30 `
  zjf@180.97.68.228
```

保持此窗口运行，再在浏览器访问 `http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote`。手动隧道由该 SSH 进程控制；**不要用 `taskkill /IM ssh.exe /F` 清除所有 SSH**，因为其他 Ray/运维隧道可能也在使用 SSH。

验证 Windows 本地是否监听：

```powershell
Get-NetTCPConnection -LocalPort 16006 -State Listen -ErrorAction SilentlyContinue
Test-NetConnection 127.0.0.1 -Port 16006
```

---

## 4. 新 A800 / 4090 机器：基础环境准备

### 4.1 云机器及容器先决条件

分别确认：Ubuntu 22.04 系、容器内 SSH 可进入、宿主机已安装兼容 NVIDIA 驱动、4090 容器有 GPU/Vulkan/NVENC 权限。记录每个容器对 Windows 可达的实际 SSH 地址/端口，以及 4090 的**容器内 IP**。

在 A800、4090 分别执行：

```bash
cat /etc/os-release
python3 --version
which ssh sshd || true
nvidia-smi
python3 -m pip --version
ip -4 -o addr show
```

在 4090 额外检查：

```bash
vulkaninfo --summary 2>/dev/null | head -35
ldconfig -p | grep -i nvidia-encode || true
nvidia-smi --query-gpu=index,name,uuid,memory.total --format=csv
```

若缺少 Vulkan/NVENC/图形相关库，应先按 GPU 云平台和目标 Isaac Sim 版本的兼容性要求安装。此项目没有能力代替云服务商修改容器 GPU 设备映射或驱动。

### 4.2 Python 与 Ray 版本统一

**固定 Ray 2.40.0，不应一台升级、另一台不升级。** 采用既有环境的 Python 3.10 解释器最稳妥：

```bash
python3 -m pip show ray || true
python3 - <<'PY'
try:
    import ray
    print(ray.__version__, ray.__file__)
except Exception as e:
    print('Ray not available:', e)
PY
```

若为新环境，可使用独立虚拟环境：

```bash
python3 -m venv "$HOME/venvs/ray240"
source "$HOME/venvs/ray240/bin/activate"
python -m pip install -U pip
python -m pip install 'ray[default]==2.40.0'
ray --version
```

**重要**：当前既有 `ray_ssh_cluster` 脚本可能使用 `python3`、`ray`、`~/.local/bin/ray` 的特定路径。若改用 venv，必须同步修改或封装这些旧脚本的解释器路径，不能仅安装 venv 后假设系统自动调用它。确认两台 `ray.__version__` 都是 `2.40.0`。

### 4.3 A800 与 4090 相互 SSH 免密

Ray 跨节点端口转发要求**两台 Linux 容器之间**也能按云平台映射端口进行 SSH 通信，仅 Windows 单向能登录不够。建议分别创建仅用于集群隧道的 SSH 密钥，交换公钥并固定主机指纹。不得将 Windows 控制机私钥直接复制给两个节点共享。

每台机器检查：

```bash
ssh -V
ls -l ~/.ssh
# 审核既有配置，无须重复生成或覆盖现有密钥
```

分别从 A800 连 4090、从 4090 连 A800 运行 `echo OK`；首次认证与 HostKey 验证完成后，必须能在 BatchMode 下无交互执行。

### 4.4 部署仓库文件到 Linux

当前 4090 已发现 `~/ray-isaac-deploy/` 目录，但**不代表完整脚本已安装**：实际曾缺少 `linux/visualization/repair-novnc.sh`。因此不能只看顶层目录是否存在。

建议在新机器上直接从私有 GitHub 仓库以只读凭据克隆，或从 Windows 传输仓库文件。Windows 示例（先在本机仓库根目录运行）：

```powershell
# 4090：创建目标目录
ssh -T -p 46602 zjf@180.97.68.228 `
  'mkdir -p ~/ray-isaac-deploy/linux'

# 将 Linux 可视化脚本目录上传
scp -P 46602 -r .\linux\visualization `
  zjf@180.97.68.228:/home/zjf/ray-isaac-deploy/linux/

# Ray 适配层如需在两台机器运行，可分别部署
scp -P 46602 -r .\linux\ray `
  zjf@180.97.68.228:/home/zjf/ray-isaac-deploy/linux/
scp -P 46885 -r .\linux\ray `
  zjf@117.74.66.77:/home/zjf/ray-isaac-deploy/linux/
```

在相应节点核对：

```bash
ls -l ~/ray-isaac-deploy/linux/visualization/
ls -l ~/ray-isaac-deploy/linux/ray/
bash -n ~/ray-isaac-deploy/linux/visualization/*.sh
bash -n ~/ray-isaac-deploy/linux/ray/*.sh
```

执行脚本时明确用 `bash path/to/script.sh`，不必依赖可执行权限或当前 Shell 为 zsh 还是 bash。

### 4.5 Ray 全新部署的重要边界

本仓库目前 **不是全自动独立 Ray 安装器**：

- `windows/deploy.ps1 -Action install -DryRun` 仅生成检查/计划；不带 `-DryRun` 并不会真正安装。
- `linux/ray/start-tunnels.sh` 代码中 `MODE="adapter"`，需要 `~/workspace/ray_ws/ray_ssh_cluster/`；`standalone` 明确输出 **UNSUPPORTED**。
- `linux/ray/cluster.sh` 调用旧工程的 `cluster_env.sh`、`head_tunnel.sh`、`worker_tunnel.sh`、`start_head.sh`、`start_worker.sh` 等脚本。这些旧脚本**没有包含在当前 Git 仓库中**。

因此，新 A800/4090 要与已验证环境等价，有两条路径：

1. **推荐：迁移已验证的 legacy Ray 适配环境。** 经检查/脱敏后迁移两侧 `~/workspace/ray_ws/ray_ssh_cluster/` 所需脚本，修改 SSH 地址、端口、接口地址、资源等，并对比端口矩阵，再启动。迁移前审查旧脚本是否含账号、令牌或私钥；不要直接把凭据放入 Git。
2. **新开发：实现 standalone Ray 双向隧道部署。** 需要完整定义两侧每一个 RPC/Agent/Worker 端口的映射、Ray CLI 启动参数、独立配置、PID/健康检查及故障恢复。目前仅配置文件列出了端口，不能把配置 YAML 当成已实现的自动隧道。

**不要**在全新机器上只执行一条 `ray start --head` 和一条 `ray start --address=...` 就认定跨机器 Ray 可用；这套环境无法直接跨容器路由，必须先打通双向端口转发。跨节点对象传输、Actor 和 GPU 调度仍需专项验证。

---

## 5. Ray 集群：各节点手动启动、检查与停止

本章“启动命令”适用于**已经安装且验收过 legacy `ray_ssh_cluster` 脚本**的机器；如果目录不存在，应先完成第 4.5 节，不要虚构脚本。

### 5.1 推荐启动顺序

1. 检查两台机器 SSH 互通和端口未被错误占用。
2. 建立并验证 Head ↔ Worker 双向 SSH 隧道。
3. 在 A800 启动 Ray Head。
4. 在 A800 借助既有脚本启动 4090 Ray Worker；或按旧工程规定从 Worker 侧启动。
5. 从 4090 查询 `ray.nodes()` 和 Ray 资源。
6. 需要证明计算任务实际能调度到 4090 时，再经授权执行 `verify_ray_active.py`（它会真正提交 GPU 任务）。

### 5.2 A800 上的手动命令

从 Windows 进入 A800：

```powershell
ssh -p 46885 zjf@117.74.66.77
```

在 A800 Linux Shell：

```bash
cd ~/workspace/ray_ws/ray_ssh_cluster
ls -l cluster_env.sh head_tunnel.sh start_head.sh start_worker.sh

# 优先只读状态
bash ./head_tunnel.sh status
pgrep -af 'gcs_server|raylet' || true
ss -ltnp | grep -E ':6379 |:22002 |:22003 ' || true

# 若服务尚未启动、且处于获准的启动窗口：
bash ./head_tunnel.sh start
bash ./start_head.sh

# 按既有脚本实现，从 A800 调用 Worker 启动（可能经 SSH 到 4090）
bash ./start_worker.sh
```

这些脚本不是当前仓库自带；其顺序与参数应以已部署的实际版本为准。**不要在发现已有运行中 Ray 进程时重复执行启动命令。**

如果 A800 已安装 toolkit 的 Ray 适配层，并且旧目录齐全：

```bash
bash ~/ray-isaac-deploy/linux/ray/start-tunnels.sh status
bash ~/ray-isaac-deploy/linux/ray/cluster.sh status
# 只有确认为停止时，才使用 start-tunnels / start-head / start-worker
```

### 5.3 4090 上的手动命令

从 Windows 进入 4090：

```powershell
ssh -p 46602 zjf@180.97.68.228
```

在 4090 Linux Shell：

```bash
cd ~/workspace/ray_ws/ray_ssh_cluster
ls -l worker_tunnel.sh cluster_env.sh
bash ./worker_tunnel.sh status
pgrep -af 'raylet|ray::' || true

# 若 4090 端所需转发尚未存在、且符合启动条件：
bash ./worker_tunnel.sh start

# 检查此机到 Head 的本地 GCS 映射（基线 127.0.0.2:6379）
ss -ltnp | grep ':6379 ' || true
```

4090 Worker 的 Ray 进程通常由 A800 的 `start_worker.sh` 通过 SSH 启动；如在 4090 本机人工执行 `ray start`，应先从 legacy 脚本查明完整固定端口、网络地址、GPU 映射与自定义资源参数，不要只写 `--address`。

### 5.4 两节点只读验证（在 4090 上执行）

```bash
python3 - <<'PY'
import ray
ray.init(address='127.0.0.2:6379', ignore_reinit_error=True,
         logging_level='ERROR')
alive = [n for n in ray.nodes() if n.get('Alive')]
print('ALIVE:', len(alive))
print('RESOURCES:', ray.cluster_resources())
for n in alive:
    print('NODE:', n.get('NodeManagerAddress'),
          'GPU:', n.get('Resources', {}).get('GPU', 0))
ray.shutdown()
PY
```

成功基线为：2 个 Alive，GPU 资源 8+1；4090 节点 `127.0.0.3` 声明 1 个 Ray GPU。此步骤只建立查询客户端，不提交 GPU Task。

### 5.5 启动验证与主动验证的区别

```powershell
.\windows\deploy.ps1 -Action status
.\windows\deploy.ps1 -Action verify -Mode passive
```

这两项属于被动检查。以下**并非**被动检查：

```powershell
# 只有经授权、资源已预留、确认不会影响已有训练时才执行
.\windows\deploy.ps1 -Action verify -Mode active -Force
```

主动验证脚本会向 4090 投递 Ray GPU 任务、测试双向对象传输和 Actor。若生产任务正在运行，不应例行执行。

### 5.6 Ray 停止或恢复（仅维护窗口）

```bash
# A800，确认所有 Ray 作业已结束并备份必要状态后
cd ~/workspace/ray_ws/ray_ssh_cluster
bash ./stop_cluster.sh
```

恢复时按“隧道 → Head → Worker”顺序。项目的 `cluster.sh recover-worker` 会**停止 Worker Ray 及隧道**，不是只读状态检查；绝不能因为一条 `status` WARN 就立即使用。若需要停一部分节点，应先检查当前 Job/Actor 的驻留情况与调度目标。

---

## 6. 4090 上 Isaac Sim 与可视化：安装、手动启动与验收

### 6.1 4090 软件清单

| 软件 | 已验证基线路径或版本 | 安装要点 |
|---|---|---|
| Isaac Sim | `/home/zjf/isaacsim`，6.2.0-rc.14 | 使用与驱动/系统兼容的对应官方构建；解压后运行包内要求的安装步骤 |
| TigerVNC | `/home/zjf/tigervnc/usr/bin/Xvnc`，1.14.1 | 用户态安装；确保配套 `libxcvt.so.0` 可由 `LD_LIBRARY_PATH` 找到 |
| noVNC | `/home/zjf/noVNC-1.5.0`，1.5.0 | 网页资源目录 |
| websockify | `/home/zjf/.local/bin/websockify`，0.13.0 | 通过 Python 启动，**只监听 127.0.0.1:6006** |
| WebRTC Client | `/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client/isaacsim-webrtc-streaming-client`，2.0.0 | Electron 客户端；在虚拟显示环境使用 `--disable-gpu` |
| CDP 自动连接 | `/home/zjf/auto_connect_webrtc.py` | 当前已验证环境使用的辅助脚本；**不在 Git 仓库内**，迁移新机时需单独复制并检查 |

**重要**：仓库 `docs/INSTALLATION.md` 有早期的下载示例，但不能据此保证某个特定预览版 ZIP/DEB 现在仍可下载。新机器先核对 NVIDIA 正式下载渠道、许可、构建版本与兼容性，再统一安装；不要把旧下载 URL 当成经验证的永久地址。

### 6.2 全新干净 4090：自动启动完整可视化栈

只适合**完全没有**在运行的 Isaac Sim、Xvnc、websockify、WebRTC Client，且包、路径、脚本均正确安装的情况。启动前：

```bash
pgrep -af 'kit/kit|Xvnc|websockify|isaacsim-webrtc' || true
ss -ltnp | grep -E ':49100 |:5901 |:6006 |:9222 ' || true
ls -l /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
ls -l ~/ray-isaac-deploy/linux/visualization/start-visualization.sh
```

在干净环境中（经授权）：

```bash
bash ~/ray-isaac-deploy/linux/visualization/start-visualization.sh
```

脚本按 Xvnc → noVNC → Isaac Sim → WebRTC Client → 自动连接执行，并写入 PID 文件。**如果已有 Isaac Sim 或 websockify 运行但缺少 PID 记录，禁止执行此整套命令**；脚本可能启动第二实例。当前用户恢复现场属于这种情况，应使用下面的分组件流程。

### 6.3 已有 Isaac Sim：只读确认，不重复启动

```bash
pgrep -af 'kit/kit' || true
ss -ltnp | grep ':49100 ' || true
ss -lunp | grep ':47998 ' || true
```

本次恢复中 Isaac Sim 实际 PID 为 `2720143`，启动参数：

```text
/home/zjf/isaacsim/kit/kit ... isaacsim.exp.full.streaming.kit
--no-window --allow-root
--/exts/omni.kit.livestream.app/primaryStream/signalPort=49100
--/exts/omni.kit.livestream.app/primaryStream/streamPort=47998
--/exts/omni.kit.livestream.app/primaryStream/publicIp=192.168.0.12
```

不能由 49100 端口监听单独推断 WebRTC 端到端成功。新容器的 `publicIp` 必须换成实际**4090 容器内可由本机 WebRTC Client 访问的 IP**，而不是机械使用 `192.168.0.12`。

若全新机器仅需**单独启动 Isaac Sim**，并且确认没有已有 Kit 进程，可在 4090 Bash 中执行（需要事先满足 Isaac Sim 的 GPU/驱动/运行环境要求）：

```bash
mkdir -p ~/.local/state/ray-isaac-deploy/logs
cd /home/zjf/isaacsim
export OMNI_KIT_ACCEPT_EULA=Y  # 仅在已阅读并接受对应许可后使用
nohup ./isaac-sim.streaming.sh --allow-root \
  --/exts/omni.kit.livestream.app/primaryStream/signalPort=49100 \
  --/exts/omni.kit.livestream.app/primaryStream/streamPort=47998 \
  --/exts/omni.kit.livestream.app/primaryStream/publicIp=192.168.0.12 \
  </dev/null > ~/.local/state/ray-isaac-deploy/logs/isaac-stream.log 2>&1 &
```

这是手动路径，**不会自动登记为 toolkit 托管进程**。需额外记录实际 Kit PID（包装脚本 PID 可能与最终 Kit PID 不同）、身份和日志；未完成登记前，不能使用全栈 stop 脚本管理它。

### 6.4 Xvnc 手动启动

```bash
# 4090 Bash：只读预检查
pgrep -ax Xvnc || true
ss -ltnp | grep ':5901 ' || true
ls -l /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
```

若无进程、端口和锁冲突：

```bash
mkdir -p ~/.local/state/ray-isaac-deploy/logs
export LD_LIBRARY_PATH="/home/zjf/tigervnc/usr/lib:${LD_LIBRARY_PATH:-}"
nohup /home/zjf/tigervnc/usr/bin/Xvnc :1 \
  -geometry 1920x1080 -depth 24 \
  -SecurityTypes None -AlwaysShared -localhost=1 -ac \
  </dev/null > ~/.local/state/ray-isaac-deploy/logs/xvnc.log 2>&1 &
echo "launcher PID=$!"
```

验证：

```bash
ss -ltnp | grep ':5901 ' || true
pgrep -ax Xvnc || true
```

应监听 `127.0.0.1:5901`（可能同时监听 `[::1]:5901`）。`-SecurityTypes None` 没有 VNC 密码，必须坚持**仅回环 + SSH 隧道**，并结合系统用户与网络权限管控。不要随意删除 `/tmp/.X1-lock`、`/tmp/.X11-unix/X1`，要先确认没有任何 X Server 占用 `:1`。

### 6.5 noVNC 手动启动及安全接管

如果完全没有 websockify，推荐首次直接回环绑定：

```bash
mkdir -p ~/.local/state/ray-isaac-deploy/logs
nohup /home/zjf/.local/bin/websockify \
  --web=/home/zjf/noVNC-1.5.0 \
  127.0.0.1:6006 127.0.0.1:5901 \
  </dev/null > ~/.local/state/ray-isaac-deploy/logs/novnc.log 2>&1 &
ss -ltnp | grep ':6006 ' || true
```

若发现旧进程已在 `0.0.0.0:6006` 监听，不要直接 `pkill websockify`，应通过 `repair-novnc.sh` 的 **Audit → Adopt → Apply** 三步进行身份验证后定向修复：

```bash
# 4090 已安装脚本时
bash ~/ray-isaac-deploy/linux/visualization/repair-novnc.sh
bash ~/ray-isaac-deploy/linux/visualization/repair-novnc.sh --adopt
# 仅在经批准的维护窗口执行；会定向重启 websockify
bash ~/ray-isaac-deploy/linux/visualization/repair-novnc.sh --apply
```

实际恢复已验证：旧 PID `2715723` 被验证、停止；新 PID `2741299` 绑定 `127.0.0.1:6006`，身份记录匹配，Isaac Sim 进程不受影响。旧脚本的公网检查输出 `000000 (REACHABLE)` 有逻辑错误，**不能据此判断公网可达**。检查公网暴露应结合绑定地址、云防火墙策略及从独立网络节点发起的合规测试。

### 6.6 WebRTC Client 单独启动与 CDP

先确保 Xvnc `:1` 在运行、`127.0.0.1:5901` 可访问；确认无同名 WebRTC Client 或 9222 监听：

```bash
pgrep -af 'isaacsim-webrtc-streaming-client' || true
ss -ltnp | grep ':9222 ' || true
```

然后在 4090 Bash 启动：

```bash
mkdir -p ~/.local/state/ray-isaac-deploy/logs
cd '/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client'
nohup env DISPLAY=:1 ./isaacsim-webrtc-streaming-client \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --ozone-platform=x11 \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  </dev/null > ~/.local/state/ray-isaac-deploy/logs/webrtc-client.log 2>&1 &
```

检查：

```bash
pgrep -af 'isaacsim-webrtc-streaming-client' || true
ss -ltnp | grep ':9222 ' || true
curl -fsS --connect-timeout 2 http://127.0.0.1:9222/json/version | head -c 500
```

9222 是无需认证的调试接口，必须绑定回环，不要开放到公网。客户端 Electron 渲染基线采用 `--disable-gpu`；不要额外使用未经验证的 SwiftShader/ANGLE 参数覆盖它。

### 6.7 连接已经在运行的 Isaac Sim

如果辅助脚本已经存在且版本与当前客户端一致：

```bash
ls -l /home/zjf/auto_connect_webrtc.py
python3 /home/zjf/auto_connect_webrtc.py 192.168.0.12 49100 47998 1920 1080
```

此命令采用本次 baseline 中的**当前容器 IP**。迁移新 4090 时必须先查询 `ip -4 -o addr show` 并改为实际地址。脚本不在当前 Git 仓库中，迁移前要校验来源及行为。

验证视频流：

```bash
tail -n 60 ~/.local/state/ray-isaac-deploy/logs/webrtc-client.log
ss -lunp | grep ':47998 ' || true
```

最终是否成功以**Windows 浏览器实际看到 Isaac Sim 画面且交互正常**为准，不仅看日志里出现字符串。若 CDP 可访问但黑屏，依次检查 Xvnc DISPLAY、Electron 进程、客户端连接界面、Kit 信令、UDP 流和容器内 IP。

### 6.8 手工启动与 PID 管理记录

`start-visualization.sh` 只有在识别到它自己的 PID 文件时才认为组件受管理。手工 `nohup` 启动后，如果未保存 `*.pid` 与 `*.identity.json`，后续全栈启动脚本仍可能重复启动它。

建议手动组件恢复后使用仓库统一的身份管理能力（或运维审核过的注册脚本），记录：`pid`、`uid`、`start_time`（`/proc/PID/stat` 第 22 字段）、`exe`、`cmdline`，并将写入操作做成原子替换。**禁止用模糊进程名直接写入 PID**，必须先确认服务真实 PID 与监听端口的对应关系。管理记录必须对应最终服务进程而非短暂存在的包装脚本。

本次已经确认 noVNC 和 Xvnc 分别通过受控流程纳入管理；如果新机器仍有未托管的 Isaac Sim，切勿为了“目录里有 PID 文件”而盲目登记或调用 stop 脚本。

---

## 7. Windows 端完整启动与手动操作

### 7.1 已有集群 + 可视化已运行（最常用）

```powershell
cd D:\workspace\isaacsim_ws\ray-isaac-deploy
.\windows\deploy.ps1 -Action status
.\windows\deploy.ps1 -Action open-viewer
.\windows\deploy.ps1 -Action verify -Mode passive
```

如果此时 Ray PASS 但端口或 WebRTC STOP，仅恢复相关可视化组件；**不要因为 status 非零就使用 `start-all.ps1`**。

### 7.2 全新干净环境首次启动（有前提）

只有当：远端正确安装 toolkit Linux 脚本；Ray legacy 隧道工程已部署；没有未托管的 Kit、websockify 或 Xvnc 实例；数据/训练已确认安全时，才考虑：

```powershell
# 在已完成脚本与依赖安装的环境中
.\windows\deploy.ps1 -Action start -Component visualization
.\windows\deploy.ps1 -Action open-viewer
```

`windows/start-all.ps1` 会**直接尝试启动整个可视化栈**，不负责审计未托管 Kit。对于当前这套曾存在未托管进程的环境，不建议设为开机自动运行。

### 7.3 明确不支持或仅部分实现的操作

| 命令/功能 | 代码现状 | 正确使用方式 |
|---|---|---|
| `-Action install -DryRun` | 只输出检查/计划 | 可以用作安装前检查，**不是安装** |
| `-Action install` | 不实施安装 | 不用于新机部署 |
| `linux/ray/start-tunnels.sh` standalone | 显式 UNSUPPORTED | 先迁移 legacy 适配层或开发完整 standalone |
| `-Action restart` | 参数接受但无实现分支 | 不可作为可靠重启命令 |
| `-Action start -Component visualization` | 调用远端硬编码路径的全栈脚本 | **仅干净/已登记且已审计的环境使用** |
| `-Action stop -Component visualization` | 调用全栈停止脚本 | 会涉及 Isaac Sim 等进程；非日常操作 |
| `-Action stop -Component ray -Force` | 可能停止整个 Ray 集群 | 仅维护停机并确认作业已完成后使用 |
| `-Action configure` | 输出 profile 的部分 JSON | 配置检查，不会自动修改 Linux 启动脚本 |

### 7.4 Windows 连接其它电脑时的注意事项

新的 Windows 客户端必须重新配置 SSH 凭据、主机指纹和 Python 环境；本机 16006 隧道是客户端自己的进程，不会随 Git 仓库迁移。不同 Windows PC 可以各建自己的本地 16006 隧道；相同一台 PC 不应运行两个竞争同一监听端口的隧道。多客户端同时接入时还需确认 Electron/VNC 的连接策略和资源占用。

---

## 8. 新实例配置：Profile、端口和不可直接迁移的硬编码

### 8.1 制作自己的 Profile

```powershell
Copy-Item .\config\cluster.example.yaml .\profiles\lab-new.yaml
notepad .\profiles\lab-new.yaml
```

需要按新环境修改：

- `hosts.a800` / `hosts.gpu4090`：SSH 主机、端口、用户。
- `ray.head.address`、`ray.worker.address`：是否仍使用原回环方案；Ray 节点与所有隧道必须一致。
- `ray.*` 固定端口与 GPU 资源；不要把 4090 物理 GPU 数直接设成 Ray 声明资源。
- `isaacsim.install_path`、`public_ip`、signal/stream 端口。
- `visualization.vnc/novnc/webrtc_client`：二进制路径、显示号和监听端口。
- `operations`：PID/日志目录。

验证 YAML：

```powershell
python .\linux\common\config_bridge.py lab-new
.\windows\deploy.ps1 -Action configure -Profile lab-new
.\windows\deploy.ps1 -Action status -Profile lab-new
```

**迁移限制**：当前 `deploy.ps1` 的启动分支和 `start-visualization.sh` 仍有 `/home/zjf/...`、`:1`、端口 49100/47998、容器 IP 等硬编码；即使 YAML 有效，也**不能认为 Linux 实际启动参数已经随 Profile 改变**。新机器如用户名/路径/端口不同，必须同步修改、审查 Linux 启动脚本，并回归测试。提交修改时把新环境 Profile 与密钥凭据分离。

### 8.2 Ray 端口矩阵（基线）

| 端点 | 用途 | 基线端口 |
|---|---|---|
| A800 Head | Ray GCS | 6379 |
| A800 Head | 节点/对象管理 | 22002、22003 |
| A800 Head | Agent / Metrics 等 | 22004–22008（以实际 legacy 脚本为准） |
| A800 Head | Worker/Driver RPC 池 | 22100–22131 |
| 4090 Worker | 节点/对象管理 | 23002、23003 |
| 4090 Worker | Agent / Metrics | 23004–23007 |
| 4090 Worker | Worker RPC 池 | 23100–23131 |

在普通 LAN/VPN 架构中 Ray 可能直接通过真实 IP 互通；但本项目明确使用**双向 SSH 隧道**，不能把 `127.0.0.2/3` 简单替换成公网 IP 就视为已部署。端口矩阵描述了目标拓扑，不是实际隧道进程存在的证据。

---

## 9. 故障诊断：按层隔离，不重启正常组件

### 9.1 Python bridge 报错或选错 Python

```powershell
python -c "import sys; print(sys.executable)"
python .\linux\common\config_bridge.py verified-20261025
.\windows\deploy.ps1 -Action configure
```

如出现无效的 Windows `python3` 别名，应使用包含 Find-Python 修复的 `de372f8` 或更新提交，不要手工猜测 Python 安装目录。

### 9.2 SSH 直接正常而 deploy.ps1 超时

```powershell
ssh -T -p 46885 -o BatchMode=yes -o ConnectTimeout=15 zjf@117.74.66.77 'echo OK'
ssh -T -p 46602 -o BatchMode=yes -o ConnectTimeout=15 zjf@180.97.68.228 'echo OK'
```

旧版本 `Register-ObjectEvent` 异步输出曾造成间歇超时；`de372f8` 使用 `ReadToEndAsync` 并对不需 stdin 的查询使用 `-n -T`，已通过 Windows 实机测试。

### 9.3 Ray 两个节点不齐

依次检查：双方 SSH → 既有 tunnel status → Head GCS/raylet → Worker raylet → Worker 上 `ray.nodes()`。不要一上来就 `stop_cluster`；尤其有实际训练任务时须先确认任务的生存与恢复策略。

### 9.4 6006 可用但页面无法连接桌面

noVNC 的 HTML 可以独立提供，但 Xvnc 5901 可能停机。检查：

```bash
ss -ltnp | grep -E ':6006 |:5901 ' || true
pgrep -af 'websockify|Xvnc' || true
```

如 6006 绑定 `0.0.0.0`，先做 Audit/Adopt/Apply 安全收敛；如 Xvnc 停止，定向恢复 :1 并确认锁文件与监听。

### 9.5 noVNC 显示空白桌面，不显示 Isaac Sim

通常说明 Xvnc 和 noVNC 已通，但 WebRTC Electron 客户端未启动/未连接。检查客户端进程、`9222/json/version`、DISPLAY、`auto_connect_webrtc.py`、49100/TCP、47998/UDP；以实际图像为最终验收。

### 9.6 Windows `verify` 因 Tunnel 16006 失败

被动验证包括本地浏览器 SSH 隧道；如果只执行了 `status` 而未运行 `open-viewer`，`Tunnel :16006` FAIL 是预期现象。先建隧道再重新执行 passive verify。禁止为了消除这一项失败而重启 Ray。

### 9.7 `zsh: no matches found` 与 Bash `$'true\r'`

多层 `ssh` + zsh 引号可能丢失，尽量只返回原始命令结果，在本地 PowerShell 用 `Select-String` 过滤。

Windows here-string 通过标准输入给 Linux Bash 时可能含 CRLF，造成 `$'true\r'`。推荐用 Python 以 UTF-8/LF 字节传输：

```powershell
$path = '.\linux\visualization\repair-novnc.sh'
python -c "import pathlib,subprocess,sys; s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig').replace('\r\n','\n'); sys.exit(subprocess.run(['ssh','-T','-p','46602','zjf@180.97.68.228','bash','-s'],input=s.encode('utf-8')).returncode)" $path
```

`repair-novnc.sh` 无参数执行的是只读 Audit。若需要 `--adopt/--apply`，它们是有状态操作，必须明确授权并保留审计记录。

---

## 10. 日志、PID 文件与运维审计

标准状态目录：`~/.local/state/ray-isaac-deploy/`。

| 文件 | 作用 |
|---|---|
| `pids/xvnc.pid` 与 `xvnc.identity.json` | Xvnc 托管标识 |
| `pids/novnc.pid` 与 `novnc.identity.json` | websockify 托管标识 |
| `pids/isaac-sim.pid` 与 `isaac-sim.identity.json` | Isaac Sim 托管标识（可能不存在） |
| `pids/webrtc-client.pid` 与 `webrtc-client.identity.json` | WebRTC 客户端托管标识 |
| `logs/xvnc.log` | Xvnc 启动与错误 |
| `logs/novnc.log` | websockify/noVNC 运行日志 |
| `logs/isaac-stream.log` | toolkit 启动的 Kit 日志；旧进程可能使用其它路径 |
| `logs/webrtc-client.log` | Electron 客户端与连接日志 |

```bash
ls -l ~/.local/state/ray-isaac-deploy/pids/
tail -n 80 ~/.local/state/ray-isaac-deploy/logs/xvnc.log
tail -n 80 ~/.local/state/ray-isaac-deploy/logs/webrtc-client.log
ss -ltnp
ss -lunp
```

停止受管理组件前，必须确保身份记录与实际 `/proc/PID` 的 **PID、UID、start_time、exe、cmdline** 一致；不要按 `pgrep -f` 的模糊结果直接发送信号。仓库的全栈停止脚本虽然有身份验证，但会按 WebRTC → Isaac Sim → noVNC → Xvnc 顺序停止，不能当作单组件停止入口。

---

## 11. 完整关机与下次开机（仅维护停机）

### 11.1 维护停机前清单

确认：Ray 任务全部结束；训练模型与检查点已保存；无人使用 VNC；已备份必要配置和日志；核对 PID/identity.json 是否完整，现有非托管进程需按现场情况单独处理。

### 11.2 可视化整套停止（维护窗口，谨慎）

```bash
# 4090：会依次尝试停止 WebRTC、Isaac Sim、noVNC、Xvnc
bash ~/ray-isaac-deploy/linux/visualization/stop-visualization.sh
```

该脚本必须存在于 4090 上。对于未登记 PID 的现有 Kit，脚本可能跳过；**不能把“脚本退出成功”解读为所有相关进程一定关闭**。停止前后都要核对 `pgrep` 和监听端口。

### 11.3 Ray 整套停止（维护窗口）

在 A800 使用经验证的 legacy `stop_cluster.sh`，并按依赖关系再收敛隧道。停止 Head 前应确保 Worker 任务已经退出。切勿日常自动运行这些步骤。

### 11.4 冷启动顺序

1. Windows SSH 能分别登录 A800、4090。
2. 检查 GPU、Python、Ray、远端脚本路径。
3. 启动 Ray 双向 SSH 隧道。
4. 启动 Ray Head，再启动 Worker，确认两节点与资源。
5. 在**完全干净的可视化环境**启动全栈；或对既有系统执行各组件的有状态安全恢复。
6. 验证 49100、47998、5901、6006、9222，以及 noVNC/CDP 回环绑定。
7. Windows 建立 `16006 → 6006` SSH 隧道，打开浏览器。
8. 确认画面、鼠标键盘、Ray 作业调度及 GPU 使用没有异常。

---

## 12. 验收清单（交付新机器时使用）

| 编号 | 项目 | 验收条件 |
|---|---|---|
| A01 | Windows | PowerShell、Git、OpenSSH、Python 可执行 |
| A02 | Git 版本 | 使用 `de372f8` 或包含对应修复的更新版本 |
| A03 | 配置 | 自定义 Profile 通过 JSON/Schema 验证 |
| A04 | SSH | Windows↔两节点、两 Linux 节点间所需免密通道可用 |
| A05 | GPU | 驱动、Vulkan、NVENC 满足实际 Isaac Sim 构建 |
| A06 | Ray Python | 两节点 Ray 2.40.0，实际执行解释器一致 |
| A07 | Ray 隧道 | legacy/正式实现的端口映射全部存在且双向可达 |
| A08 | Ray 资源 | 2 Alive，A800 8 + 4090 1（若采用原资源配置） |
| A09 | Isaac Sim | 49100 监听、47998 UDP 可用、Kit 完整加载 |
| A10 | Xvnc | :1 存活，5901 回环监听 |
| A11 | noVNC | 6006 回环监听，页面可读取、VNC 可连接 |
| A12 | WebRTC Client | 进程存活、CDP 9222 回环监听 |
| A13 | 视频 | 4090 本机客户端连接 49100/47998 且 Windows 可见实际画面 |
| A14 | PID 安全 | 服务 PID/identity.json 完整、一致；无意外重复实例 |
| A15 | Windows 入口 | `status`、`open-viewer`、`verify -Mode passive` 正常运行且退出码如实反映健康状态 |
| A16 | 生产边界 | 没有无授权 Ray GPU Task、全栈重启、全端口外网暴露 |

---

## 附录 A：重要文件与命令索引

```text
仓库
├── windows/deploy.ps1                       Windows 主入口（v1.1.1）
├── windows/open-isaacsim.ps1                Windows 浏览器隧道入口
├── windows/start-all.ps1                    全栈启动；非日常接管首选
├── windows/stop-all.ps1                     全栈停止；维护窗口使用
├── linux/common/config_bridge.py           Profile YAML → JSON
├── linux/ray/cluster.sh                     legacy Ray 控制适配器
├── linux/ray/start-tunnels.sh               legacy 隧道适配器
├── linux/ray/verify-cluster.sh              主动 Ray 验证；非被动
├── linux/visualization/start-visualization.sh  全栈启动、PID 管理
├── linux/visualization/stop-visualization.sh   全栈停止、身份验证
├── linux/visualization/repair-novnc.sh      Audit / Adopt / Apply
├── profiles/verified-20261025.yaml         已验证的基线环境
├── config/cluster.example.yaml              新环境配置模板
├── config/cluster.schema.json               配置约束
├── baseline/working_baseline.json           原始验证现场记录
└── tests/powershell/deploy_regression_tests.ps1  13 项回归检查
```

## 附录 B：当前恢复现场记录（便于交接）

截至本次会话提供的日志：

- Ray：A800 Head + 4090 Worker，2 Alive，GPU 声明 8+1。
- Isaac Sim：Kit PID `2720143`，未被 toolkit PID 文件管理，**不可盲目重复启动**。
- noVNC：从旧 PID `2715723` 受控迁移到 `2741299`，`127.0.0.1:6006`，PID 身份匹配。
- Xvnc：已定向恢复，PID `2741483`，`:1`，IPv4/IPv6 均回环，身份记录已保存。
- 用户随后反馈“好了，可以了”，表明实际可视化已能使用；WebRTC Client 新 PID、CDP 监听及视频质量的完整最终日志**未在聊天中给出**，不应在手册里编造其具体 PID。
- 原本曾出现 `6006` 全接口绑定的风险已经通过回环监听修复；旧 Audit 输出 `000000 (REACHABLE)` 属于错误字符串判断，不能作为外部可达性证据。

## 附录 C：参考源及版本边界

- 私有仓库：`https://github.com/CornerOfSkyline/ray-isaac-deploy`
- Windows 修复 PR：`https://github.com/CornerOfSkyline/ray-isaac-deploy/pull/2`
- 代码来源：`profiles/verified-20261025.yaml`、`baseline/working_baseline.json`、`docs/{ARCHITECTURE,PORT_MATRIX,INSTALLATION,OPERATIONS,RECOVERY}.md`、Windows/Linux 脚本及 2026-10-27 的实机日志。

**提示**：本手册将“已验证的当前环境”和“尚需补齐的全新部署能力”分开陈述。对于新服务器，如果 Ray 双向隧道脚本或 `/home/zjf/auto_connect_webrtc.py` 缺失，必须先获得对应的已验证实现并完成现场验收；不能把尚未实现的自动安装功能当成可用命令。