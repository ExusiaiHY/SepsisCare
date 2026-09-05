const { app, BrowserWindow, dialog } = require("electron");
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");

const API_PORT = process.env.SEPSISCARE_PORT || "8765";
const LOCAL_API_BASE = `http://127.0.0.1:${API_PORT}`;
const CLOUD_API_BASE = "http://100.65.136.96:8788";
const API_BASE = process.env.SEPSISCARE_API_BASE_URL || LOCAL_API_BASE;
let backendProcess = null;
let isQuitting = false;

function isPackaged() {
  return app.isPackaged;
}

function resourcePath(...parts) {
  return isPackaged()
    ? path.join(process.resourcesPath, ...parts)
    : path.join(__dirname, ...parts);
}

function webIndexPath() {
  const packaged = resourcePath("web", "index.html");
  const dev = path.join(__dirname, "renderer", "web", "index.html");
  return fs.existsSync(packaged) ? packaged : dev;
}

function backendServerPath() {
  const packaged = resourcePath("backend", "server.py");
  const devCandidates = [
    path.resolve(__dirname, "../sepsiscare-studio/backend/server.py"),
    path.resolve(__dirname, "../../../04_client_source/apps/sepsiscare-studio/backend/server.py")
  ];
  if (fs.existsSync(packaged)) return packaged;
  return devCandidates.find(candidate => fs.existsSync(candidate)) || devCandidates[0];
}

function modelPackagePath() {
  const packaged = resourcePath("02_model_deploy_package");
  const devCandidates = [
    path.resolve(__dirname, "../../02_model_deploy_package"),
    path.resolve(__dirname, "../../../03_remote_server_model_package/02_model_deploy_package")
  ];
  if (fs.existsSync(packaged)) return packaged;
  return devCandidates.find(candidate => fs.existsSync(candidate)) || devCandidates[0];
}

function bundledPythonPath() {
  if (process.platform !== "win32") return null;
  const packaged = resourcePath("python-embed", "python.exe");
  const dev = path.join(__dirname, "vendor", "python-3.12.10-embed-amd64", "python.exe");
  if (fs.existsSync(packaged)) return packaged;
  if (fs.existsSync(dev)) return dev;
  return null;
}

function pythonCandidates() {
  if (process.env.SEPSISCARE_PYTHON) return [[process.env.SEPSISCARE_PYTHON, []]];
  const bundled = bundledPythonPath();
  const candidates = bundled ? [[bundled, []]] : [];
  return process.platform === "win32"
    ? candidates.concat([["py", ["-3"]], ["python", []], ["python3", []]])
    : [["python3", []], ["python", []]];
}

function startBackend() {
  if (process.env.SEPSISCARE_DISABLE_BACKEND_AUTOSTART === "1") return;
  if (API_BASE !== LOCAL_API_BASE && process.env.SEPSISCARE_FORCE_BACKEND_AUTOSTART !== "1") return;
  if (backendProcess && backendProcess.exitCode === null && !backendProcess.killed) return;
  const serverPath = backendServerPath();
  if (!fs.existsSync(serverPath)) return;
  const candidates = pythonCandidates();

  function tryStart(index) {
    const [python, prefixArgs] = candidates[index] || [];
    if (!python) {
      dialog.showErrorBox(
        "sepsiscare 本地后端未启动",
        "无法启动 Python 后端。Windows 安装包通常自带 Python；如该文件被安全软件移除，请重新安装，或设置 SEPSISCARE_PYTHON 指向 python.exe。"
      );
      return;
    }
    const args = [...prefixArgs, serverPath, "--host", "127.0.0.1", "--port", API_PORT];
    const runtimeRoot = path.join(app.getPath("userData"), "runtime");
    const deployRoot = modelPackagePath();
    const child = spawn(python, args, {
      cwd: path.dirname(serverPath),
      env: {
        ...process.env,
        NO_PROXY: process.env.NO_PROXY || "127.0.0.1,localhost,0.0.0.0,::1",
        no_proxy: process.env.no_proxy || process.env.NO_PROXY || "127.0.0.1,localhost,0.0.0.0,::1",
        PYTHONUNBUFFERED: "1",
        SEPSISCARE_DEVICE: process.env.SEPSISCARE_DEVICE || "cpu",
        SEPSISCARE_DEPLOY_ROOT: deployRoot,
        SEPSISCARE_RUNTIME_ROOT: runtimeRoot,
        SEPSISCARE_PUBLIC_API_BASE_URL: LOCAL_API_BASE,
        SEPSISCARE_PUBLIC_MODEL_BASE_URL: process.env.SEPSISCARE_MODEL_BASE_URL || LOCAL_API_BASE
      },
      windowsHide: true
    });
    let failedToSpawn = false;
    child.stdout.on("data", data => console.log(`[backend] ${data}`));
    child.stderr.on("data", data => console.error(`[backend] ${data}`));
    child.on("error", error => {
      failedToSpawn = true;
      console.error(`backend start failed with ${python}: ${error.message}`);
      tryStart(index + 1);
    });
    child.on("exit", code => {
      if (!failedToSpawn) console.log(`backend exited with ${code}`);
      if (backendProcess === child) backendProcess = null;
      if (!isQuitting && code !== 0) {
        console.error("backend stopped unexpectedly; it will be started again when the app is activated.");
      }
    });
    backendProcess = child;
  }

  tryStart(0);
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 1100,
    minHeight: 720,
    title: "sepsiscare",
    backgroundColor: "#07101d",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });
  const index = webIndexPath();
  if (!fs.existsSync(index)) {
    dialog.showErrorBox("sepsiscare", "未找到共享 Web 客户端资源，请先运行 npm run sync:web。");
    return;
  }
  win.loadFile(index, { query: { api: API_BASE, platform: "windows" } });
}

app.whenReady().then(() => {
  startBackend();
  createWindow();
  app.on("activate", () => {
    startBackend();
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  isQuitting = true;
  if (backendProcess && !backendProcess.killed) backendProcess.kill();
});
