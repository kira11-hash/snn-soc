## 10. 服务器代理/VPN 使用教程（校园网内机器）

### 目的

在校园网内服务器（如 `zjueda*` 节点）上，通过**本机已开启的代理/VPN**访问外网（用于 `pip` / `git` / `codex` / `curl` 等）。

当前约定：

- 本机（Windows）代理端口：`7897`
- 服务器使用 `~/.bashrc` 中的函数：
  - `proxy_on`
  - `proxy_off`
  - `proxy_test`

---

### 一、先明确两个概念（避免混淆）

1. **本机 PowerShell**（Windows）
   - 用来查看本机 IP（`ipconfig`）
   - 不能用 `export ...`（这是 Linux 命令）

2. **服务器 Linux Shell**（SSH 登录后）
   - 用来执行 `proxy_on / proxy_test`
   - 用来跑 `python / pip / codex`

---

### 二、日常使用（最常见场景）

#### 场景 A：换服务器节点（例如从 `zjueda1` 换到 `zjueda2`）

如果本机 IP 没变，直接在**服务器**执行：

```bash
source ~/.bashrc
proxy_on
proxy_test
```

如果 `proxy_test` 能返回 Google 的 HTTP 头（`HTTP/2 200` 等），说明该节点代理可用。

然后就可以继续：

```bash
python -m pip install 包名
# 或运行 codex / git / curl 等
```

---

#### 场景 B：本机“梯子换节点”，但本机局域网 IP 没变

通常**不用改服务器配置**，只需要在服务器重新确认代理可用：

```bash
proxy_on
proxy_test
```

如果不通，再按“场景 C”检查本机 IP 是否变化。

---

### 三、当本机 IP 变化时（必须改）

> 常见于：重连校园网、换 Wi-Fi、重新获取 DHCP 地址。

#### 步骤 1：在本机（Windows）查看当前 IP

打开 PowerShell：

```powershell
ipconfig
```

看 **无线局域网适配器 WLAN** 的 `IPv4 地址`，例如：

- `10.97.41.116`（这是可用的校园网内地址）

注意：

- **用 `WLAN` 的 IPv4 地址**
- **不要用** `Meta` 适配器里的 `28.x.x.x`（那是 VPN 虚拟网卡地址）

---

#### 步骤 2：在服务器修改 `~/.bashrc` 中的 IP

编辑服务器上的 `~/.bashrc`，把这一行改成新的本机 IP：

```bash
export LOCAL_PROXY_HOST="10.97.41.116"
```

例如用 `vi`：

```bash
vi ~/.bashrc
```

搜索 `LOCAL_PROXY_HOST`，改完保存退出。

---

#### 步骤 3：在服务器重新加载并测试

```bash
source ~/.bashrc
proxy_on
proxy_test
```

如果 `proxy_test` 成功，即可继续使用外网。

---

### 四、首次排障（代理不通时按顺序检查）

如果 `proxy_test` 失败，按下面顺序查：

1. **本机 VPN/代理是否开着**
   - 确保本机代理端口 `7897` 正常工作

2. **本机 VPN 客户端是否开启 `Allow LAN` / 允许局域网连接**
   - 没开的话，服务器无法访问你本机 `7897`

3. **本机防火墙是否放行 `7897`**
   - 至少允许校园网内服务器访问该端口

4. **本机 IP 是否变化**
   - 再执行一次 `ipconfig`

5. **当前服务器节点是否可达你本机**
   - 在服务器执行：
   ```bash
   curl -x http://<你的本机IP>:7897 https://www.google.com -I
   ```

---

### 五、手动临时设置（不走 `proxy_on` 函数时）

在服务器临时设置（只对当前 shell 会话有效）：

```bash
export http_proxy=http://10.97.41.116:7897
export https_proxy=http://10.97.41.116:7897
export HTTP_PROXY=$http_proxy
export HTTPS_PROXY=$https_proxy
export ALL_PROXY=$http_proxy
```

验证：

```bash
curl -I https://www.google.com
```

---

### 六、快速检查清单（推荐保存脑内流程）

#### 换节点后（优先做这个）

1. `source ~/.bashrc`
2. `proxy_on`
3. `proxy_test`
4. 成功后再跑 `python/pip/codex`

#### 如果不通

1. 本机 `ipconfig` 看 `WLAN` IPv4
2. 改服务器 `~/.bashrc` 里的 `LOCAL_PROXY_HOST`
3. `source ~/.bashrc && proxy_on && proxy_test`

---

### 七、补充说明（和当前项目相关）

- 当前代理配置只解决“服务器访问外网”的问题（如安装 `openpyxl`、运行 `codex`）。
- 与 Python 建模结果本身无关，但会影响插件依赖安装与联网能力。
- 每次准备在服务器上跑关键流程（尤其 full run）前，建议先执行一次：

```bash
proxy_test
```

确保网络可用后再开始长任务。


---

### ??Remote-SSH ?? Codex/Claude Code ????????????

???? **VS Code Remote-SSH** ???????/?? AI ??????????????????/??????????
- ???????? `proxy_on`?? **VS Code ??????** ?????????????

???????????????????

```bash
~/.vscode-server/server-env-setup
```

???????????? IP/??????

```bash
export http_proxy=http://10.97.41.116:7897
export https_proxy=http://10.97.41.116:7897
export HTTP_PROXY=$http_proxy
export HTTPS_PROXY=$https_proxy
export ALL_PROXY=$http_proxy
```

?????? VS Code ???
1. `Remote-SSH: Kill VS Code Server on Host...`
2. ????????

??????????????????????????????

> ???`curl -I https://api.openai.com` ??????????????????? `auth.openai.com` ?? Cloudflare challenge?403???????????????????????? API Key ???
