# 飞书 Codex Agent Bridge

一个运行在 Windows 电脑上的自托管桥接器：把飞书机器人的消息、截图、文件和语音转给本机的 Codex CLI，并将执行状态和结果回复到飞书。

```text
飞书消息 -> 飞书长连接 -> Bridge -> Codex CLI -> 本地工作区
     ^                                             |
     +--------------- 飞书卡片回复 ----------------+
```

它适合把一台始终开机的 Windows 电脑作为远程 Agent 主机，用手机上的飞书交代代码、文档、图片分析或本机文件操作任务。

> 这是自托管工具，不是飞书或 OpenAI 的官方产品。机器人拥有的权限等于其所在 Windows 账户及 `projects.json` 暴露给它的目录权限。

## 功能

- 通过飞书 WebSocket 长连接接收私聊和群聊消息，无需公网回调地址。
- 调用本机已登录的 Codex CLI；默认不设置任务时限，可在飞书中手动终止。
- 支持纯文字、截图加文字、富文本、多张图片、文件、语音和合并转发。
- 将图片或文件下载到本地工作区后交给 Codex 处理。
- 支持项目路由、话题、会话续接、执行进度、任务终止及长文本分段回复。
- 带 Windows 启动、停止、状态、自检和迁移脚本。
- 对飞书卡片更新做节流和重试；Codex 已完成但 CLI 残留时会在短暂宽限后自动收尾。

## 前提条件

1. Windows 10/11，PowerShell 5.1 或更新版本。
2. [Bun](https://bun.sh/) 已安装，或先执行 `scripts/install-bun.ps1`。
3. Codex CLI 已安装并在该 Windows 用户下完成登录。
4. 已创建飞书自建应用并启用机器人能力。

建议使用专门的 Windows 账户运行本工具，并只把允许 Agent 操作的目录写入 `projects.json`。

## 飞书配置

在飞书开放平台创建自建应用后：

1. 启用 **机器人** 能力，并发布应用版本。
2. 在“事件与回调”中选择“使用长连接接收事件/回调”。
3. 订阅事件 `im.message.receive_v1`。
4. 申请并发布所需权限。基础消息处理通常需要：
   - `im:message`
   - `im:message.group_at_msg`
   - `im:resource`
5. 复制 App ID 和 App Secret，填入本地 `config/bridge.env`。

需要搜索飞书文档、访问云盘或按用户身份调用 API 时，还需要按功能额外申请对应的飞书权限，并通过 `scripts/feishu-user-oauth.js` 完成用户授权。

## 安装

克隆仓库后，在仓库根目录执行：

```powershell
Copy-Item .\config\bridge.env.example .\config\bridge.env
notepad .\config\bridge.env

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-bun.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

`setup.ps1` 第一次执行时会从 `projects.json.example` 生成本机专用的 `projects.json`，并把默认工作区指向本仓库的 `runtime` 目录。

## 配置 Codex

在 `config/bridge.env` 保留或设置以下值：

```dotenv
AGENT_BIN=../scripts/codex-agent-adapter.cmd
CODEX_AGENT_TIMEOUT_MS=0
FEISHU_APP_ID=cli_xxxxxxxxxxxxxxxx
FEISHU_APP_SECRET=your_app_secret
```

`CODEX_AGENT_TIMEOUT_MS=0` 表示不自动中止长任务。需要限制时填毫秒数，例如 `3600000` 表示一小时。

Codex 登录状态不在本仓库中。请在目标 Windows 用户下先打开 Codex 或完成 Codex CLI 登录，再启动桥接器。

## 启动与维护

前台启动，适合第一次排查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
```

后台启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-background.ps1
```

查询或停止：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

日志位于 `runtime/logs/feishu-cursor.log`。生产使用建议用 Windows 任务计划程序启动 `scripts/start.ps1`，并设置“用户登录时运行”。

## 飞书中的使用方式

直接向机器人发送任务即可，例如：

```text
检查这个项目的构建错误并修复。
```

截图可与说明文字一起发送。飞书会把这类消息包装为富文本，Bridge 会提取文字并下载其中的图片，再交给 Codex。

常用指令：

- `/帮助`：查看完整指令列表。
- `/状态`：查看桥接服务状态。
- `/终止`：终止当前执行中的任务。
- `/新对话`：归档当前会话并开始新会话。
- `/话题`：查看、创建或切换话题。
- `/会话`：查看并切换当前话题下的历史会话。

一个话题对应一条可续接的 Codex 会话。新建话题或执行 `/新对话` 会让后续任务使用新的上下文。

## 项目路由与权限边界

`projects.json` 是本机私有配置，不会提交到 Git。它决定机器人可操作的工作区：

```json
{
  "projects": {
    "local": {
      "path": "E:/Agent/lark-agent-bridge/runtime",
      "description": "默认工作区"
    },
    "myapp": {
      "path": "E:/work/myapp",
      "description": "业务代码仓库"
    }
  },
  "default_project": "myapp"
}
```

飞书消息前加 `myapp:` 可以指定项目；未加前缀时使用 `default_project`。不要把不希望 Agent 读取或修改的目录加入该文件。

## 迁移到另一台 Windows 电脑

私有迁移包包含 `config/bridge.env`，可能含飞书 App Secret 和 OAuth 令牌，不能上传或分享：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\export-migration.ps1
```

在新电脑解压后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-migration.ps1
```

同一个飞书 App 同时只应有一个桥接实例在线；迁移后先停止旧电脑上的桥接器。

## 安全说明

以下文件均在 `.gitignore` 中，不会上传：

- `config/bridge.env` 和 `claw/.env` 中的 App Secret、OAuth 令牌及 API Key。
- `projects.json` 中的本机路径。
- `runtime/`、下载附件、日志、会话和话题状态。
- `migration-packages/` 中可能包含密钥的迁移压缩包。
- Codex 登录态、Git 凭据、SSH 私钥和浏览器 Cookie。

提交前仍建议运行一次密钥扫描，并确认 `git status --ignored` 中只有预期的本机文件。
