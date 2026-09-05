# SepsisCare macOS app + final model transfer package

打包日期：2026-05-28

这个包用于把 SepsisCare 的 macOS app 端源码和最终部署模型迁移到另一台电脑继续开发。

## 包内容

- `SepsisCare-macOS/`
  - SwiftUI macOS app 源码
  - `Package.swift`
  - app 资源、测试、DMG 构建脚本
- `02_model_deploy_package/`
  - 最终云端部署模型：`s7_phenotype_contrastive_full_20260516`
  - 模型权重、phenotype readout、转移矩阵、配置、训练报告
  - 轻量模型服务：`deploy/model_service.py`
- `apps/sepsiscare-studio/backend/server.py`
  - macOS app 本地开发兼容后端
  - 用于补齐迁移包中缺失的 studio 后端入口，让 Xcode 直接运行时能通过 `http://127.0.0.1:8765/health`

## 原始来源

- app 源目录：
  `/Users/exusiaihy/Desktop/Python高阶程序设计/project/apps/SepsisCare-macOS`
- 模型部署包：
  `/Users/exusiaihy/Desktop/SepsisCare_Final_Delivery_20260518/02_model_deploy_package`

## 新电脑恢复步骤

1. 解压 zip。
2. 安装 Xcode 15+，确保命令行里可用 Swift 5.9+。
3. 使用项目级启动脚本构建并打开 macOS app。不要用 `swift run` 启动 GUI app；SwiftPM 裸可执行文件可能没有正常的 bundle identifier、Dock 激活和前台窗口。

```bash
./script/build_and_run.sh --verify
```

开发脚本生成的本地调试包使用 `care.sepsis.desktop.dev`，安装包和 DMG 使用 `care.sepsis.desktop`。这样可以避免开发版 `dist/SepsisCare-macOS.app` 和 `/Applications/SepsisCare-macOS.app` 同时存在时，macOS LaunchServices 把窗口激活到错误副本。

4. 如果只做编译/单测，可以单独运行：

```bash
cd SepsisCare-macOS
swift build
swift test
```

5. App 启动后会自动寻找并启动或复用：

```bash
python3 apps/sepsiscare-studio/backend/server.py --host 127.0.0.1 --port 8765
```

6. 如需单独启动最终模型服务：

```bash
cd ../02_model_deploy_package
bash deploy/start_model_service.sh
```

7. app 本地后端健康检查：

```bash
curl http://127.0.0.1:8765/health
```

8. 最终模型服务健康检查：

```bash
curl http://127.0.0.1:8788/health
```

9. app 默认 API 地址在 `SepsisCare-macOS/Sources/App/APIClient.swift`：

```swift
static let cloudBaseURL = "http://106.55.230.127"
static let localBaseURL = "http://127.0.0.1:8765"
```

继续开发时优先在 app 设置页切换到目标后端地址，不需要改源码。API 地址会自动去掉首尾空白和结尾 `/`，例如 `http://目标电脑IP:8765/` 会保存为 `http://目标电脑IP:8765`；裸 IPv6 地址例如 `http://fd00::20:8765/` 会保存为 `http://[fd00::20]:8765`。设置页的 `测试 API` 按钮会把规范化后的地址同步到 App 后端控制器和 APIClient，先检查地址格式，再直接请求 `/health`；成功和失败都会在设置页显示明确状态。模型部署包默认服务端口是 `8788`，而 app 的离线备用后端默认是 `8765`；如果要直接让 app 调本地服务，需要确认后端接口路径是否和 app 期望的 `/api/...` 端点一致。

## 本地和远程部署目标

当前迁移包推荐先跑通两层服务：

1. macOS app 兼容后端：`apps/sepsiscare-studio/backend/server.py`
   - 默认地址：`http://127.0.0.1:8765`
   - 面向 macOS 前端，提供 `/health`、`/api/patients`、`/api/model/metadata`、训练终端、管理员状态等 app 端需要的接口。
   - Xcode 直接运行 app 时会自动启动；如果端口上已经有健康实例，后端会复用现有服务，不再因为 `Address already in use` 崩溃。

2. 最终模型服务：`02_model_deploy_package/deploy/model_service.py`
   - 默认地址：`http://127.0.0.1:8788`
   - 面向云端训练终端、模型成果接口和 remote server 远程数据库，提供 `/health`、`/api/model/status`、`/api/training/command`、`/api/artifacts/latest`，以及 macOS smoke 覆盖的患者/历史/admin/AI/床旁接口。

### 本机前端 + 另一台 model 机

如果 macOS App 和兼容 API 保留在本机，只把最终模型服务放到另一台电脑：

1. 本机保持 API 在线：

```bash
cd SepsisCare_macOS_app_model_transfer_20260528
./script/sepsiscare_services.sh agent-status
```

2. 另一台 model 电脑只启动 `8788` 模型服务：

```bash
cd SepsisCare_macOS_app_model_transfer_20260528/02_model_deploy_package
export SEPSISCARE_SERVICE_TOKEN="$(openssl rand -hex 24)"
SEPSISCARE_MODEL_HOST=0.0.0.0 SEPSISCARE_MODEL_PORT=8788 bash deploy/remote_server_one_click_deploy.sh restart
SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" bash deploy/remote_server_one_click_deploy.sh smoke
```

`SEPSISCARE_SERVICE_TOKEN` 是远端敏感 API、训练命令和 artifact 下载的 Bearer token。不要提交到 Git，也不要写入文档、聊天记录、日志或 shell history；只在临时 shell、secret manager、部署进程、smoke 和客户端环境中注入。Token must be non-placeholder text with at least 16 characters; weak values such as demo passwords, `password`, `token`, or copied placeholder text make remote sensitive endpoints fail closed.

3. 回到本机验证 API 会真实转发到 model 电脑：

```bash
SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" ./script/smoke_test.sh http://127.0.0.1:8765 http://MODEL电脑IP:8788 --require-model
```

这条 `--require-model` smoke 会先把训练终端配置为 `production`，再要求 `/api/training-terminal/action` 返回 `已转发至云端模型服务` 和 model service 的 `cloud_response`。它验证的是本机 API -> 另一台 model service 的真实连接，不只是分别检查两个 `/health`。

如果要把 remote server 直接作为完整远程 API 和 model server 验证：

```bash
SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" ./script/smoke_test.sh http://REMOTE_SERVER_IP:8788 http://REMOTE_SERVER_IP:8788 --require-model
curl -H "Authorization: Bearer $SEPSISCARE_SERVICE_TOKEN" -o sepsiscare_model_artifacts_latest.zip http://REMOTE_SERVER_IP:8788/api/artifacts/latest
```

如果已经能从本机 SSH 到 remote server，可以使用本机一键编排脚本同步模型包、在 remote server 上启动模型服务、从本机验证转发链路，并把最新模型 artifact 拉回本地：

```bash
REMOTE_SERVER_HOST=remote-server \
REMOTE_SERVER_DIR=~/SepsisCare_macOS_app_model_transfer_20260528 \
REMOTE_SERVER_MODEL_URL=http://remote-server:8788 \
SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" \
./script/deploy_model_to_remote_server.sh all
```

部署、smoke 和 artifact 拉取完成后，在临时 shell 中清理 token：

```bash
unset SEPSISCARE_SERVICE_TOKEN
```

这个脚本会依次执行：

- `preflight`: 检查本机到 remote server 的 SSH。
- `sync`: rsync `02_model_deploy_package/` 到 remote server，排除 `.runtime/`、`artifacts/`、`.venv/` 和 Python 缓存。
- `deploy`: 在 remote server 上运行 `deploy/remote_server_one_click_deploy.sh restart` 和 `smoke`。
- `smoke`: 从本机运行 `./script/smoke_test.sh http://127.0.0.1:8765 http://REMOTE_SERVER:8788 --require-model`。
- `pull-artifacts`: 从 `http://REMOTE_SERVER:8788/api/artifacts/latest` 拉回 `.sepsiscare-runtime/remote-server-artifacts/sepsiscare_model_artifacts_latest.zip`。

只跑单步可以使用：

```bash
./script/deploy_model_to_remote_server.sh preflight
./script/deploy_model_to_remote_server.sh sync
./script/deploy_model_to_remote_server.sh deploy
./script/deploy_model_to_remote_server.sh smoke
./script/deploy_model_to_remote_server.sh pull-artifacts
```

要把服务放到另一台电脑供本机 app 远程连接，先在目标电脑启动兼容后端：

```bash
cd SepsisCare_macOS_app_model_transfer_20260528
python3 apps/sepsiscare-studio/backend/server.py --host 127.0.0.1 --port 8765
```

只有在可信 VPN/LAN 内确实需要让另一台电脑访问兼容后端时，才显式使用 `--host 0.0.0.0`，并同时设置 `SEPSISCARE_SERVICE_TOKEN`。否则管理、患者、历史、训练和 AI 端点会拒绝远端访问。

如果目标电脑也要同时提供最终模型服务，使用统一部署入口：

```bash
cd SepsisCare_macOS_app_model_transfer_20260528
./script/sepsiscare_services.sh start
./script/sepsiscare_services.sh status
./script/sepsiscare_services.sh smoke
```

`status` 会同时输出远程访问自检信息：API/model 实际监听地址、是否只监听 loopback、是否需要检查防火墙/VPN/LAN 路由，以及客户端应运行的 `./script/remote_deployment_check.sh TARGET_IP`。

如果 `start` 报告端口已经被占用但 `/health` 不通，先运行：

```bash
./script/sepsiscare_services.sh status
```

然后停止占用该端口的旧进程，或改用其他端口，例如：

```bash
SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh start
```

如果目标电脑是 macOS，建议安装为当前用户的 LaunchAgent，避免手动打开 Terminal 后才能常驻运行：

```bash
cd SepsisCare_macOS_app_model_transfer_20260528
./script/sepsiscare_services.sh install-agent
./script/sepsiscare_services.sh agent-status
./script/sepsiscare_services.sh smoke
```

卸载 LaunchAgent：

```bash
./script/sepsiscare_services.sh uninstall-agent
```

然后在本机 app 设置页把 API 地址改成：

```text
http://目标电脑IP:8765
```

点击设置页里的 `测试 API`，确认状态更新为在线后再进入研究端、家属端或管理员端。

远程健康检查：

```bash
curl http://目标电脑IP:8765/health
curl http://目标电脑IP:8788/health
```

本地完整 smoke test：

```bash
./script/smoke_test.sh
```

如果 8788 模型服务也已启动：

```bash
./script/smoke_test.sh --require-model
```

当前本地验收记录见 `DEPLOYMENT_TEST_REPORT.md`。

从本机验证另一台电脑：

```bash
./script/remote_deployment_check.sh 目标电脑IP
```

如果目标电脑用域名、非默认端口或 IPv6，可以用显式参数。传 `--host` 时 IPv6 可以写裸地址，脚本会自动拼成带方括号的 URL；如果在 app 设置页或 `--api-url` 中手写完整 IPv6 URL，则使用 `http://[IPv6地址]:8765`：

```bash
./script/remote_deployment_check.sh --host server.local --api-port 18080 --model-port 18081
./script/remote_deployment_check.sh --host fd00::20 --api-port 8765 --model-port 8788
./script/remote_deployment_check.sh --api-url http://[fd00::20]:8765 --model-url http://[fd00::20]:8788
```

这个预检会从客户端视角检查：

- `http://目标电脑IP:8765/health`
- `http://目标电脑IP:8788/health`
- app API 主要业务端点 smoke test
- 模型服务 `/api/training/command` smoke test
- 常见失败会输出部署提示，包括目标电脑服务状态、`0.0.0.0` 监听、防火墙/VPN/LAN 路由和端口暴露。

如果只验证 app API，不要求目标电脑提供 8788 模型服务：

```bash
./script/remote_deployment_check.sh --api-url http://目标电脑IP:8765 --skip-model
```

也可以直接调用底层 smoke test：

```bash
./script/smoke_test.sh http://目标电脑IP:8765 http://目标电脑IP:8788 --require-model
```

修改预检脚本后，先跑回归测试：

```bash
./script/test_remote_deployment_check.sh
```

停止目标电脑上的服务：

```bash
./script/sepsiscare_services.sh stop
```

## 注意

- 这个包没有包含原始 ICU 训练数据和大型中间数据集。
- 这个包没有包含 Xcode DerivedData、`.build`、`dist`、`.DS_Store`、Python `__pycache__` 等可再生缓存。
- 原始总仓库当前存在大量未提交和数据删除状态；本包只按迁移需求复制 app 源码和最终模型部署包，没有修改原仓库。
