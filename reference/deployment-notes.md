# Super-agent 自托管部署笔记（2026-11-02，脱敏原始素材）

目的：把一次真实部署的环境、操作和故障写下来，供编写 `docs/OPERATIONS.md` 使用。事实为准，不要美化。

## 1. 环境

- 宿主：Windows 11（build 26200），WSL 2.7.8 / Linux 内核 6.18.33
- 发行版：Ubuntu 24.04.5（ubuntu-base rootfs 手动导入；无 systemd；单 root 用户）
- DSH：`@deepseek-ai/dsh` 0.2.1-rc.3（npm 全局安装）
- 隔离：`DSH_HOME=/root/.dsh`，与 Windows 宿主 `~/.dsh` 完全隔离（不共享 sessions/凭据/MCP 配置）
- 插件：`dsh-superagent-prototype`（commit `6337fc8`）。`pnpm install && pnpm build` 后，以 link 方式装入 profile `superagent`
- 模型：DeepSeek API；`DEEPSEEK_API_KEY` 由宿主环境经 WSLENV 注入（不落盘）
- Source：GitHub（Issue 评论 @agent 触发）；面板 `http://127.0.0.1:3082`
- 并发：`maxWorkers=3`；每个 Ticket 一个独立工作目录，位于 `<stateDir>/work`

## 2. 启动 / 停止 / 状态

- profile 配置：`/root/.dsh/profiles/superagent/cordis.patch.yml`（webserver `127.0.0.1:3082`、stateDir `/root/.dsh/state/superagent`）
- 启动：tmux 会话 `dsh-superagent` 中运行 `dsh --profile superagent --no-open`；或用仓库自带 `scripts/dsh-superagent start|stop|status`
- 面板 token：每次启动会变化，位于 `/root/dsh-superagent/.artifacts/dsh-superagent-superagent-*.log` 首行；不要硬编码
- 管理 API：`http://127.0.0.1:3082/orchestrator/api`，必须带请求头 `x-orchestrator-request: 1`，否则 401/拒绝

## 3. 真实故障（按发生顺序）

1. **原生 Windows 不可行（记录，供理解为何用 WSL）**：源码要求路径 schema 以 `/` 开头、worker-bin shim 是 `#!/bin/sh`、prepare 命令走 `sh -c`、控制脚本是 POSIX Python（fcntl/tmux）。这不是配置问题。
2. **GitHub 网络**：Windows 侧用 Steam++/Watt Toolkit 加速，原理是 hosts→`127.0.0.1` + 本地 MITM CA。WSL 不继承 Windows 的 hosts 与证书库，直接访问 GitHub 超时（`gh` 换 token 时 i/o timeout）。
   处理：导出 MITM 根 CA 到 WSL 信任库；`/etc/hosts` 把 github 相关域名指向 Windows 宿主网关；`/etc/wsl.conf` 的 `[boot] command` 按 `/proc/net/route` 动态刷新网关；验证 `curl` 返回 200 且证书校验通过。
3. **轮询游标**：GitHub mention 通知晚于评论到达时，Source 游标已越过该评论 → 旧评论不补读（设计如此，不是 bug）。处理：重新评论一次。
4. **邮箱自动回复噪音**：operator 的邮箱自动回复被 GitHub 邮件网关转发成 Issue 评论，worker 正确判为“无请求”。处理：关闭该邮箱对 GitHub 通知的自动回复。
5. **凭据暴露面**：worker 与编排器同 uid，可读 `/proc/<pid>/environ` 拿到模型 key。处理：建议为服务单独建限额 key（未完成）。
6. **进程识别**：node 主线程在 procps 的 `ucomm` 显示为 `MainThread`，控制脚本按进程名匹配 worker 会失败；本地补丁把 `MainThread` 加入匹配（上游可修）。

## 4. 安全边界（现状）

- worker：`danger-full-access`、root；WSL 内可读 `/mnt/c`（Windows 文件）
- 白名单：Policy 只允许 operator 账号发起；agent 自身消息被 Source 丢弃（不能自己给自己派活）
- 面板仅监听 `127.0.0.1`，无公网暴露
- 建议：worker 降权/容器化、关闭 `/mnt/c`、独立限额 key、开机自启需显式批准

## 5. 验证过的闭环

Issue 评论（operator）→ Ticket → worker clone 仓库 → 改文件 → push 分支 → 开 PR → 回帖。约 1 分钟完成。
