# SepsisCare 机器学习模型训练终端使用与交付说明

版本：0.9.1  
适用端：macOS、Windows、Android/WebView  
后端模块：`apps/sepsiscare-studio/backend/training_terminal.py`

## 1. 模块定位

训练终端是独立于患者队列、风险看板、历史 ICU 数据库、DeepSeek 问答之外的运维模块。客户端提供可视化按钮和命令输入框；后端只维护训练终端配置、日志、模拟状态，并在生产模式下把指令转发到云端训练服务。

当前课程演示阶段使用本地演示模型与安装包内置数据，不执行本机 shell 指令。正式投产阶段，模型本体应迁移到云端算力服务器，由训练终端远程下发继续训练、暂停、日志查看、权重下载等指令。

## 2. 最终三类交付物

1. 软件一体式安装包  
   macOS `.dmg`、Windows `.exe`、Android `.apk`。macOS/Windows 安装包内置本地后端和演示数据；Android WebView 需要连接可达的 PC 后端或云端 API。

2. 模型本体文件  
   `local_demo`：课程演示版模型，用于无云端算力时展示预测与训练控制流。  
   `cloud_production`：正式部署版模型，放置在云端算力服务器，训练终端通过 API 调用。

3. 完整使用说明书  
   包含安装、启动、训练终端配置、云端模型部署、快捷键、故障排查、演示限制和投产迁移说明。

## 3. 训练终端 API

本地后端新增接口：

- `GET /api/training-terminal/status`：读取当前模式、训练状态、指标、参数。
- `GET /api/training-terminal/logs?limit=80`：读取最近训练终端日志。
- `GET /api/training-terminal/config`：读取配置。
- `GET /api/training-terminal/artifacts`：读取成果文件记录。
- `POST /api/training-terminal/config`：保存模式、云端地址、训练参数。
- `POST /api/training-terminal/action`：执行快捷动作。
- `POST /api/training-terminal/command`：发送自定义训练指令。

云端模型服务还需要提供 ICU 实时时序数据闭环：

- `GET /api/icu/timeseries/status?limit=5`：读取远端已接收事件数、已训练事件数、是否有待训练事件和最近事件。
- `POST /api/icu/timeseries/ingest`：接收院内 ICU 监护接口上传的脱敏生命体征、化验和设备元数据。
- `POST /api/training/command {"action":"continue_training"}`：读取尚未训练的 ICU 事件并更新 `incremental_icu_adapter.json`。验收时必须看到 `actual_training_examples > 0`、`incremental_adapter_loss`、`incremental_adapter_path` 和训练后 `trained_event_count == total_events`；不能只以接口返回 200 作为训练成功证据。

生产模式下，后端会把动作转发到：

```text
{SEPSISCARE_TRAINING_CLOUD_URL}/api/training/command
```

云端训练服务需要接受 JSON：

```json
{
  "client": "sepsiscare-training-terminal",
  "type": "action",
  "action": "continue_training",
  "mode": "production",
  "model_profile": "cloud_production",
  "params": {}
}
```

推荐云端返回：

```json
{
  "ok": true,
  "task_status": "running",
  "metrics": {"epoch": 12, "loss": 0.231, "accuracy": 0.884},
  "output": ["cloud job resumed", "epoch=12 loss=0.231"]
}
```

## 4. 配置方法

本地演示：

```text
SEPSISCARE_TRAINING_MODE=demo
SEPSISCARE_TRAINING_CLOUD_URL=
```

云端生产：

```text
SEPSISCARE_TRAINING_MODE=production
SEPSISCARE_TRAINING_CLOUD_URL=http://云端服务器IP:端口
SEPSISCARE_TRAINING_TOKEN=可选的云端鉴权token
```

也可以在软件内的“训练终端”页面直接填写云端训练服务地址并保存。

## 5. 快捷按钮与快捷键

- `Ctrl/Command+1`：一键更新业务数据库。
- `Ctrl/Command+2`：一键发起云端模型继续训练。
- `Ctrl/Command+3`：一键暂停云端模型训练任务。
- `Ctrl/Command+4`：一键下载权重成果、数据集、日志文件。
- `Ctrl/Command+5`：一键查看实时日志、损失值、精度数据。
- `Ctrl/Command+6`：一键切换本地演示模型 / 云端生产模型。
- `Ctrl/Command+7`：一键重置训练参数。
- `Ctrl/Command+8`：一键同步本地配置至云端。

自定义指令输入框可发送 `status`、`train --resume`、`show metrics`、`download artifacts` 等训练相关指令。演示模式只做安全模拟与日志记录，不会执行任意本地命令。

## 6. 云端部署对接流程

1. 在云端算力服务器部署模型本体、数据目录和训练脚本。
2. 启动一个训练服务，提供 `POST /api/training/command` 接口。
3. 在训练服务内实现动作映射：继续训练、暂停训练、读取日志、读取指标、打包成果。
4. 在 SepsisCare 客户端训练终端填写云端服务地址。
5. 切换到“云端生产模型”，点击“同步配置”，再执行训练操作。

免费轻量服务器适合演示 API 对接、日志回显和小规模 smoke，不适合长时间 GPU 训练或大数据集训练。正式投产需要具备稳定存储、GPU/CPU 算力、备份、鉴权、任务队列和日志保留策略。

## 7. 新电脑安装后的能力边界

macOS/Windows 新电脑安装后可以直接使用本地演示数据、历史库查询、风险看板、训练终端演示模式。能否继续跑真实训练取决于是否随交付物安装了本地演示模型，或是否配置了云端生产模型地址。

Android 安装包不内置 Python 后端和本地模型运行环境。Android 可以打开训练终端页面，但必须连接云端 API 或同局域网可访问的 PC 后端，才能获取真实状态和下发指令。
