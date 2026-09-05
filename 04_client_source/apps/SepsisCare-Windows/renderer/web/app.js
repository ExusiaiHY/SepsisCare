const launchParams = new URLSearchParams(window.location.search);
const PLATFORM = launchParams.get("platform") || "web";
const IS_MOBILE_SHELL = PLATFORM === "android" || PLATFORM === "ios";
const LAUNCH_API = launchParams.get("api");
const LAUNCH_API_TOKEN = launchParams.get("token") || launchParams.get("apiToken");
const STORED_API = localStorage.getItem("sepsiscare.api");
const SESSION_API_TOKEN = sessionStorage.getItem("sepsiscare.apiToken");
const LEGACY_STORED_API_TOKEN = localStorage.getItem("sepsiscare.apiToken");
const CLOUD_API_BASE = "http://100.65.136.96:8788";
const LEGACY_CLOUD_API_BASE = "http://106.55.230.127";
const LOCAL_API_BASE = "http://127.0.0.1:8765";
const API_DEFAULT = chooseApiBase(LAUNCH_API, STORED_API, window.SEPSISCARE_API_BASE_URL);
const APP_VERSION = "0.9.1";
const API_TIMEOUT_MS = 3500;
const DEMO_PASSWORD = "123123";
const DEMO_AUTH_BOUNDARY_NOTICE = "演示界面门禁，不是生产认证；远端敏感接口仍以 Token 控制。";

const demoPatients = Array.from({ length: 12 }, (_, index) => {
  const phenotypeNames = ["低灌注-高乳酸型", "炎症高反应型", "肾功能受累型", "呼吸循环混合型"];
  const riskLevels = ["🔴 高风险", "🟠 观察", "🟢 稳定", "🟢 恢复"];
  return {
    masked_id: `DEMO-${String(index + 1).padStart(3, "0")}`,
    bed_no: `ICU-${12 + index}`,
    icu_ward: index % 2 === 0 ? "综合 ICU" : "急诊 ICU",
    phenotype_name: phenotypeNames[index % phenotypeNames.length],
    risk_level: riskLevels[index % riskLevels.length],
    risk_score: Math.max(0.08, 0.91 - index * 0.06),
    los_hours: 18 + index * 9
  };
});

const state = {
  role: localStorage.getItem("sepsiscare.role") || (IS_MOBILE_SHELL ? "family" : "research"),
  apiBase: API_DEFAULT,
  apiToken: normalizeApiToken(LAUNCH_API_TOKEN || SESSION_API_TOKEN || LEGACY_STORED_API_TOKEN || window.SEPSISCARE_API_TOKEN || ""),
  password: "",
  authenticated: false,
  page: "overview",
  patients: [],
  selectedPatient: null,
  apiStatus: "checking",
  apiError: "",
  queueOpen: false,
  historyRows: [],
  historyStats: null,
  patientDetails: {},
  lastFamilyRefresh: "",
  messages: [],
  trainingStatus: null,
  trainingOutput: "训练终端已就绪。演示模式不会执行本机 shell；生产模式会把指令转发到配置的云端训练服务。",
  realtimeStatus: null,
  realtimeOutput: "ICU 实时时序接口已就绪。",
  deepSeekConfig: null,
  deepSeekStatus: ""
};

let familyRefreshTimer = null;
if (state.apiToken) sessionStorage.setItem("sepsiscare.apiToken", state.apiToken);
localStorage.removeItem("sepsiscare.apiToken");
scrubLaunchSecretsFromUrl();

const pages = {
  research: [
    ["overview", "总览工作台", "队列、风险、历史库、模型入口"],
    ["risk", "风险看板", "当前患者风险分诊与实时趋势"],
    ["history", "历史 ICU 数据库", "已出院训练队列与预测一致性"],
    ["clinical", "临床模型实验室", "诊断/S6/评分/床旁接口"],
    ["realtime", "实时 ICU 接入", "监护时序入库与云端上传"],
    ["training", "训练终端", "云端训练运维"],
    ["ai", "AI 分析", "研究端解释与问答"],
    ["docs", "使用文档", "公式与 API 文档入口"]
  ],
  family: [
    ["chat", "AI 智能体沟通", "绑定患者解释问答"],
    ["familyStatus", "当前患者状态", "基础状态与可读摘要"]
  ],
  admin: [
    ["accounts", "账号绑定", "家属账号与患者绑定"],
    ["services", "服务监控", "后端/CPU/GPU/DeepSeek"],
    ["api", "API 覆盖", "接口巡检"],
    ["audit", "审计日志", "本地调用记录"]
  ]
};

const trainingActions = [
  ["update_database", "更新数据库", "Ctrl/⌘1"],
  ["continue_training", "继续训练", "Ctrl/⌘2"],
  ["pause_training", "暂停训练", "Ctrl/⌘3"],
  ["download_artifacts", "下载成果", "Ctrl/⌘4"],
  ["stream_metrics", "日志指标", "Ctrl/⌘5"],
  ["switch_mode", "切换模式", "Ctrl/⌘6"],
  ["reset_params", "重置参数", "Ctrl/⌘7"],
  ["sync_config", "同步配置", "Ctrl/⌘8"]
];

function $(selector) { return document.querySelector(selector); }
function el(tag, className = "", html = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (html) node.innerHTML = html;
  return node;
}
function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
}
function safeText(value) { return escapeHTML(value); }
function safeAttr(value) { return escapeHTML(value); }
function safeJSON(value) { return escapeHTML(JSON.stringify(value, null, 2)); }
function normalizeApiBase(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}
function normalizeApiToken(value) {
  let normalized = String(value || "").trim();
  if (/^bearer\s+/i.test(normalized)) normalized = normalized.replace(/^bearer\s+/i, "").trim();
  return normalized;
}
function scrubLaunchSecretsFromUrl() {
  if (!window.history?.replaceState) return;
  const url = new URL(window.location.href);
  if (!url.searchParams.has("token") && !url.searchParams.has("apiToken")) return;
  url.searchParams.delete("token");
  url.searchParams.delete("apiToken");
  window.history.replaceState(window.history.state, document.title, `${url.pathname}${url.search}${url.hash}`);
}
function isLegacyDefaultApi(value) {
  if (normalizeApiBase(value) === LEGACY_CLOUD_API_BASE) return true;
  return /^https?:\/\/(127\.0\.0\.1|localhost|10\.0\.2\.2|10\.20\.197\.82)(:\d+)?$/i.test(normalizeApiBase(value));
}
function displayCloudBase(value) {
  const normalized = normalizeApiBase(value);
  if (/^https?:\/\/(127\.0\.0\.1|localhost|\[?::1\]?)(:\d+)?$/i.test(normalized) && !isLegacyDefaultApi(state.apiBase)) {
    return state.apiBase;
  }
  return normalized;
}
function chooseApiBase(launchApi, storedApi, windowApi) {
  const launch = normalizeApiBase(launchApi);
  const stored = normalizeApiBase(storedApi);
  const windowBase = normalizeApiBase(windowApi);
  if (launch && !isLegacyDefaultApi(launch)) {
    localStorage.setItem("sepsiscare.api", launch);
    return launch;
  }
  if (stored && isLegacyDefaultApi(stored)) {
    localStorage.setItem("sepsiscare.api", CLOUD_API_BASE);
    return CLOUD_API_BASE;
  }
  if (windowBase && !isLegacyDefaultApi(windowBase)) return windowBase;
  localStorage.setItem("sepsiscare.api", CLOUD_API_BASE);
  return CLOUD_API_BASE;
}
function saveApiBase(value) {
  const next = normalizeApiBase(value);
  if (!next) return false;
  state.apiBase = next;
  localStorage.setItem("sepsiscare.api", next);
  state.apiStatus = "checking";
  state.apiError = "";
  state.patients = [];
  state.selectedPatient = null;
  state.patientDetails = {};
  state.historyStats = null;
  return true;
}
function saveApiToken(value) {
  const next = normalizeApiToken(value);
  state.apiToken = next;
  if (next) sessionStorage.setItem("sepsiscare.apiToken", next);
  else sessionStorage.removeItem("sepsiscare.apiToken");
  localStorage.removeItem("sepsiscare.apiToken");
}
function roleTitle(role) {
  return role === "research" ? "研究端" : role === "family" ? "家属端" : "管理员端";
}
function riskClass(risk) {
  if (String(risk).includes("🔴") || risk === "critical") return "risk-critical";
  if (String(risk).includes("🟠") || risk === "watch") return "risk-watch";
  return "risk-stable";
}
async function api(path, options = {}) {
  const controller = new AbortController();
  const slowPath = /^\/api\/(ai\/|family\/chat|training-terminal\/|icu\/realtime\/upload)/.test(path);
  const timeoutMs = options.timeoutMs || (slowPath ? 25000 : API_TIMEOUT_MS);
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  const { timeoutMs: _ignoredTimeoutMs, ...fetchOptions } = options;
  try {
    const headers = { "Content-Type": "application/json", ...(fetchOptions.headers || {}) };
    if (state.apiToken) headers.Authorization = `Bearer ${state.apiToken}`;
    const response = await fetch(`${state.apiBase}${path}`, {
      ...fetchOptions,
      headers,
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`${response.status} ${path}`);
    const type = response.headers.get("content-type") || "";
    state.apiStatus = "online";
    state.apiError = "";
    return type.includes("text/csv") ? response.text() : response.json();
  } catch (error) {
    state.apiStatus = "offline";
    state.apiError = error.name === "AbortError" ? `连接超时：${path}` : error.message;
    throw error;
  } finally {
    window.clearTimeout(timeout);
  }
}

function useDemoPatients(reason = "") {
  if (!state.patients.length) {
    state.patients = demoPatients;
    state.selectedPatient = demoPatients[0];
  }
  state.apiStatus = "demo";
  if (reason) state.apiError = reason;
}

async function refreshPatients() {
  try {
    const data = await api("/api/patients?page=1&per_page=50");
    state.patients = data.patients || [];
    if (!state.selectedPatient || !state.patients.some(p => p.masked_id === state.selectedPatient.masked_id)) {
      state.selectedPatient = state.patients[0] || null;
    }
    if (!state.patients.length) useDemoPatients("后端没有返回患者队列，已切换到 demo 队列。");
    return true;
  } catch (error) {
    useDemoPatients(`后端暂不可达，已切换到 demo 队列。${state.apiError || error.message}`);
    return false;
  }
}

function buildDemoPatientDetail(patient = demoPatients[0]) {
  const index = Math.max(0, demoPatients.findIndex(item => item.masked_id === patient.masked_id));
  const base = {
    heart_rate: 88 + index * 3,
    pulse: 88 + index * 3,
    resp_rate: 18 + index,
    spo2: Math.max(89, 98 - index),
    sbp: 118 - index,
    dbp: 72 - Math.round(index / 3),
    map: 82 - Math.round(index / 2),
    temperature: 36.8 + index * 0.08,
    gcs: 15
  };
  const labs = { lactate: 1.5 + index * 0.18, wbc: 8.2 + index * 0.5, creatinine: 0.9 + index * 0.04 };
  const history = Array.from({ length: 25 }, (_, pointIndex) => {
    const hour = -48 + pointIndex * 2;
    return {
      hour,
      heart_rate: Number((base.heart_rate + Math.sin(pointIndex / 2) * 7).toFixed(1)),
      pulse: Number((base.pulse + Math.cos(pointIndex / 2.2) * 6).toFixed(1)),
      resp_rate: Number((base.resp_rate + Math.sin(pointIndex / 2.8) * 2).toFixed(1)),
      spo2: Number(Math.min(100, base.spo2 + Math.cos(pointIndex / 3) * 1.2).toFixed(1)),
      sbp: Number((base.sbp + Math.sin(pointIndex / 3.5) * 5).toFixed(1)),
      dbp: Number((base.dbp + Math.cos(pointIndex / 3.5) * 4).toFixed(1)),
      map: Number((base.map + Math.sin(pointIndex / 3.3) * 4).toFixed(1)),
      temperature: Number((base.temperature + Math.sin(pointIndex / 4) * 0.25).toFixed(1)),
      lactate: Number((labs.lactate + Math.cos(pointIndex / 4) * 0.2).toFixed(2))
    };
  });
  return {
    patient,
    vitals: base,
    labs,
    blood_gas: { ph: 7.4, pao2: 92, paco2: 41, fio2: 0.28 },
    prediction: { latest: { phenotype: { family_label: patient.phenotype_name, description: "当前为离线演示摘要" } } },
    history,
    updated_at: new Date().toISOString()
  };
}

async function refreshSelectedPatientDetail({ force = false } = {}) {
  const selected = state.selectedPatient || state.patients[0] || demoPatients[0];
  if (!selected?.masked_id) return null;
  if (!force && state.patientDetails[selected.masked_id] && state.apiStatus !== "online") {
    return state.patientDetails[selected.masked_id];
  }
  try {
    const detail = await api(`/api/patients/${encodeURIComponent(selected.masked_id)}`);
    state.patientDetails[selected.masked_id] = detail;
    state.lastFamilyRefresh = detail.updated_at || new Date().toISOString();
    return detail;
  } catch (error) {
    const detail = state.patientDetails[selected.masked_id] || buildDemoPatientDetail(selected);
    state.patientDetails[selected.masked_id] = detail;
    state.lastFamilyRefresh = new Date().toISOString();
    return detail;
  }
}

function renderLogin() {
  const app = $("#app");
  const availableRoles = ["research", "family", "admin"];
  app.className = "app-shell";
  app.innerHTML = `
    <section class="login">
      <div class="card">
        <div class="brand-row">
          <div class="logo"></div>
          <div>
            <h1 class="title">sepsiscare <span class="pill">v${APP_VERSION}</span></h1>
            <p class="subtitle">ICU sepsiscare intelligence workspace</p>
          </div>
        </div>
        <div class="role-grid ${IS_MOBILE_SHELL ? "single-role" : ""}">
          ${availableRoles.map(role => `
            <button class="role ${state.role === role ? "active" : ""}" data-role="${role}">
              <strong>${roleTitle(role)}</strong>
              <span>${role === "research" ? "科研分析与队列管理" : role === "family" ? "绑定患者沟通摘要" : "账户绑定与系统监控"}</span>
            </button>
          `).join("")}
        </div>
        <div class="input-row">
          <input id="password" type="password" placeholder="请输入演示密码，默认 ${DEMO_PASSWORD}" autocomplete="current-password">
          <button class="primary" id="loginButton">进入${roleTitle(state.role)}</button>
        </div>
        <div class="api-settings">
          <label for="apiBaseInput">后端 API</label>
          <div class="input-row">
            <input id="apiBaseInput" type="url" value="${escapeHTML(state.apiBase)}" placeholder="${CLOUD_API_BASE}" autocapitalize="off" spellcheck="false">
            <button class="secondary" id="saveApiButton">保存</button>
          </div>
          <div class="input-row">
            <input id="apiTokenInput" type="password" value="" placeholder="${state.apiToken ? "Token 已配置，留空保留" : "远端服务 Token，可粘贴 Bearer token"}" autocomplete="off">
          </div>
          <p>${safeText(DEMO_AUTH_BOUNDARY_NOTICE)} 远端患者、训练、AI 和 artifact 接口需要 Token；Token 仅保留在本次会话，本机 demo 可留空。</p>
        </div>
        <div class="error" id="loginError"></div>
      </div>
      <div class="card">
        <span class="pill">4-platform shell</span>
        <h2>${IS_MOBILE_SHELL ? "家属端移动应用" : "统一 API 与打包入口"}</h2>
        <p class="subtitle">${IS_MOBILE_SHELL ? "手机端只保留家属端功能：绑定患者状态、AI 沟通辅助和可读摘要。" : "Windows 使用 Electron/WebView2，iOS 使用 WKWebView，Android 使用 WebView；三端共享这一套页面，macOS 保留原生 SwiftUI。"}</p>
        <div class="console-list">
          <div class="console-row"><b>API</b><span>${safeText(state.apiBase)}</span></div>
          <div class="console-row"><b>后端</b><span>${safeText(state.apiBase)}</span></div>
          <div class="console-row"><b>Token</b><span>${state.apiToken ? "已配置" : "未配置"}</span></div>
          <div class="console-row"><b>DeepSeek</b><span>DeepSeek via server.py，未配置时本地降级</span></div>
        </div>
      </div>
    </section>`;
  document.querySelectorAll(".role").forEach(button => {
    button.onclick = () => { state.role = button.dataset.role; localStorage.setItem("sepsiscare.role", state.role); renderLogin(); };
  });
  $("#saveApiButton").onclick = () => {
    const tokenInput = $("#apiTokenInput")?.value || "";
    if (tokenInput.trim() || !state.apiToken) saveApiToken(tokenInput);
    if (saveApiBase($("#apiBaseInput").value)) {
      $("#loginError").textContent = state.apiToken ? "API 地址已保存，Token 仅保留在本次会话。" : "API 地址已保存；远端敏感接口仍需要 Token。";
    } else {
      $("#loginError").textContent = "请输入有效 API 地址。";
    }
  };
  $("#loginButton").onclick = () => {
    const tokenInput = $("#apiTokenInput")?.value || "";
    if (tokenInput.trim()) saveApiToken(tokenInput);
    if ($("#password").value.trim() !== DEMO_PASSWORD) {
      $("#loginError").textContent = `密码错误，请输入演示密码 ${DEMO_PASSWORD}`;
      return;
    }
    state.authenticated = true;
    state.page = pages[state.role][0][0];
    useDemoPatients();
    if (state.role === "family") startFamilyAutoRefresh();
    renderWorkspace();
    refreshPatients().then(() => {
      if (state.authenticated) renderWorkspace();
    });
  };
}

function renderWorkspace() {
  const app = $("#app");
  app.className = `app-shell ${state.role === "family" ? "family-mode" : ""}`;
  const currentPages = pages[state.role];
  app.innerHTML = `
    <section class="workspace">
      <aside class="sidebar">
        <div class="brand-row"><div class="logo"></div><div><h1 class="title">sepsiscare</h1><p class="subtitle">${safeText(roleTitle(state.role))}</p></div></div>
        <nav class="nav">${currentPages.map(([id, title, sub]) => `<button class="${state.page === id ? "active" : ""}" data-page="${id}"><b>${title}</b><small>${sub}</small></button>`).join("")}</nav>
      </aside>
      <section class="content">
        <div class="topbar">
          <div><span class="pill ${state.apiStatus === "online" ? "" : "warn"}">${state.apiStatus === "online" ? "API online" : "离线 demo"}</span> <span class="pill">${safeText(state.apiBase)}</span> <span class="pill">${safeText(state.selectedPatient?.masked_id || "未选择患者")}</span></div>
          <div class="top-actions"><button class="secondary" id="changeApi">API</button> <button class="primary" id="refresh">刷新</button> <button class="primary" id="logout">退出</button></div>
        </div>
        <div id="page"></div>
      </section>
      ${state.role !== "admin" ? renderQueueHTML() : ""}
    </section>`;
  document.querySelectorAll("[data-page]").forEach(button => button.onclick = () => { state.page = button.dataset.page; renderWorkspace(); });
  $("#refresh").onclick = async () => { await refreshPatients(); renderWorkspace(); };
  $("#changeApi").onclick = () => {
    const next = window.prompt("请输入后端 API 地址", state.apiBase);
    if (next && saveApiBase(next)) {
      refreshPatients().then(() => renderWorkspace());
    }
  };
  $("#logout").onclick = () => {
    state.authenticated = false;
    if (familyRefreshTimer) window.clearInterval(familyRefreshTimer);
    renderLogin();
  };
  if ($("#queueToggle")) $("#queueToggle").onclick = () => { state.queueOpen = !state.queueOpen; renderWorkspace(); };
  document.querySelectorAll("[data-patient]").forEach(button => button.onclick = () => {
    state.selectedPatient = state.patients.find(p => p.masked_id === button.dataset.patient) || state.selectedPatient;
    renderWorkspace();
  });
  renderPage();
}

function renderQueueHTML() {
  return `<div class="queue">
    <button class="queue-toggle" id="queueToggle">${state.patients.length || "队列"}</button>
    <div class="queue-panel ${state.queueOpen ? "" : "hidden"}">
      <b>患者队列</b>
      ${(state.role === "family" ? state.patients.slice(0, 1) : state.patients.slice(0, 8)).map(p => `
        <button class="queue-row row-button ${state.selectedPatient?.masked_id === p.masked_id ? "active" : ""}" data-patient="${safeAttr(p.masked_id)}">
          <span><b>${safeText(p.masked_id)}</b><br><small>${safeText(p.bed_no)} · ${safeText(p.icu_ward)} · ${safeText(p.phenotype_name)}</small></span>
          <span class="${riskClass(p.risk_level)}">${safeText(p.risk_level)}</span>
        </button>`).join("")}
    </div>
  </div>`;
}

function pageTitle(title, subtitle) {
  return `<div class="page-title"><h2>${safeText(title)}</h2><p>${safeText(subtitle)}</p></div>`;
}
function metric(title, value, subtitle) {
  return `<div class="metric"><span>${safeText(title)}</span><b>${safeText(value)}</b><span>${safeText(subtitle)}</span></div>`;
}
function vitalCard(title, value, unit, subtitle, canvasId, tone = "") {
  return `<div class="vital-card ${tone}">
    <div class="vital-card-head"><span>${safeText(title)}</span><b>${safeText(value ?? "--")}<small>${safeText(unit)}</small></b></div>
    <canvas id="${safeAttr(canvasId)}"></canvas>
    <p>${safeText(subtitle)}</p>
  </div>`;
}
function formatTimestamp(value) {
  if (!value) return "--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString("zh-CN", { hour12: false, month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}
function patientTable(rows) {
  if (!rows || !rows.length) return `<div class="empty">暂无患者数据。</div>`;
  return `<table class="table"><thead><tr><th>患者</th><th>病区</th><th>表型</th><th>风险</th><th>LOS</th></tr></thead><tbody>
    ${rows.map(p => `<tr><td>${safeText(p.masked_id || "--")}<br><small>${safeText(p.bed_no || "--")}</small></td><td>${safeText(p.icu_ward || "--")}</td><td>${safeText(p.phenotype_name || "--")}</td><td class="${riskClass(p.risk_level)}">${safeText(p.risk_level || "--")}</td><td>${safeText(Math.round(p.los_hours || 0))}h</td></tr>`).join("")}
  </tbody></table>`;
}

async function renderPage() {
  const page = $("#page");
  const selected = state.selectedPatient || state.patients[0] || {};
  if (state.page === "overview") {
    if (!state.historyStats && state.apiStatus === "online") {
      try { state.historyStats = await api("/api/history/stats"); } catch (_) {}
    }
    const critical = state.patients.filter(p => String(p.risk_level).includes("🔴")).length;
    const historyTotal = (state.historyStats?.total ?? state.historyRows.length) || "500";
    page.innerHTML = `${pageTitle("总览工作台", "四端共享 API 合同，研究端聚合当前队列、历史库和模型实验室。")}
      <div class="metrics">${metric("当前队列", state.patients.length, "院内 ICU 当前样本")}${metric("高风险", critical, "优先进入风险看板")}${metric("历史 ICU", historyTotal, "已出院训练队列")}${metric("后端", "online", state.apiBase)}</div>
      ${state.apiStatus !== "online" ? `<div class="notice">${safeText(state.apiError || "后端暂不可达，当前显示离线 demo 数据。")}</div>` : ""}
      <div class="section"><h3>最近患者快照</h3>${patientTable(state.patients.slice(0, 10))}</div>`;
  } else if (state.page === "risk") {
    page.innerHTML = `${pageTitle("风险看板", "风险看板和临床模型实验室分析对象来自右下角患者队列。")}
      <div class="metrics">${metric("当前患者", selected.masked_id || "--", selected.bed_no || "请选择")}${metric("表型", selected.phenotype_name || "--", "当前模型输出")}${metric("风险", selected.risk_level || "--", "研究端可查看量化风险")}${metric("LOS", `${Math.round(selected.los_hours || 0)}h`, "模型估计")}</div>
      <div class="split"><div class="section"><h3>高风险队列</h3>${patientTable(state.patients.slice().sort((a,b)=>b.risk_score-a.risk_score).slice(0, 12))}</div><div class="section"><h3>48h 实时趋势</h3><canvas id="trend"></canvas></div></div>`;
    drawTrend("trend");
  } else if (state.page === "history") {
    if (!state.historyRows.length) {
      try {
        const data = await api("/api/history/patients?page=1&per_page=20");
        state.historyRows = data.patients || [];
      } catch (_) {
        state.historyRows = demoPatients.map((patient, index) => ({
          masked_id: patient.masked_id,
          data_source: index % 2 === 0 ? "physionet2019" : "eicu-crd",
          icu_type: patient.icu_ward,
          outcome: index % 4 === 0 ? "死亡" : "存活",
          phenotype_consistency: { label: ["完全一致", "大部分一致", "平均", "大部分不一致"][index % 4] }
        }));
      }
    }
    page.innerHTML = `${pageTitle("历史 ICU 数据库", "已出院训练队列，点击详情可做分钟级趋势和预测一致性复核。")}
      <div class="section"><h3>历史患者</h3><table class="table"><thead><tr><th>ID</th><th>来源</th><th>ICU</th><th>结局</th><th>一致性</th></tr></thead><tbody>${state.historyRows.map(r => `<tr><td>${safeText(r.masked_id)}</td><td>${safeText(r.data_source)}</td><td>${safeText(r.icu_type)}</td><td>${safeText(r.outcome)}</td><td>${safeText(r.phenotype_consistency?.label)}</td></tr>`).join("")}</tbody></table></div>`;
  } else if (state.page === "clinical") {
    page.innerHTML = `${pageTitle("临床模型实验室", "诊断工作台、S6 亚型、临床评分和床旁快照的四端共享入口。")}
      <div class="metrics">${metric("诊断", "/api/diagnose", "单例/批量")}${metric("S6", "/api/sepsis-subtypes", "metadata/predict/recommend")}${metric("评分", "/api/clinical/scores", "SOFA/qSOFA/NEWS")}${metric("床旁", "/api/bedside", "beds/snapshot/report")}</div>
      <div class="section"><h3>当前分析对象</h3>${patientTable([selected])}</div>`;
  } else if (state.page === "realtime") {
    await renderRealtimePage(page);
  } else if (state.page === "training") {
    await renderTrainingPage(page);
  } else if (state.page === "ai") {
    page.innerHTML = `${pageTitle("AI 分析", "研究端 AI 问答与解释，接入 server.py 的 DeepSeek 配置。")}<div class="section"><h3>助手输出</h3><button class="primary" id="askAI">运行 AI 分析</button><pre id="aiOutput"></pre></div>`;
    $("#askAI").onclick = async () => { $("#aiOutput").textContent = JSON.stringify(await api("/api/ai/analysis"), null, 2); };
  } else if (state.page === "docs") {
    page.innerHTML = `${pageTitle("使用文档", "公式说明和 API 合同以项目 docs 为准，移动端保留阅读入口。")}<div class="section"><p>请打开 docs/SEPSISCARE_4_PLATFORM_SETUP_AND_PACKAGING.md 查看完整四端运行、依赖安装和打包流程。</p></div>`;
  } else if (state.page === "chat") {
    page.innerHTML = `${pageTitle("AI 智能体沟通", "家属端只展示绑定患者，不量化死亡风险，不提供治疗建议。")}
      <div class="section chat" id="chatBox">${state.messages.map(m => `<div class="message ${safeAttr(m.role)}">${safeText(m.text)}</div>`).join("")}</div>
      <div class="toolbar"><input id="chatInput" placeholder="输入想问医生前需要了解的问题"><button class="primary" id="sendChat">发送</button></div><div class="disclaimer">免责声明：仅用于沟通辅助，不构成诊断、治疗建议或转归承诺。</div>`;
    $("#sendChat").onclick = sendChat;
  } else if (state.page === "familyStatus") {
    const detail = await refreshSelectedPatientDetail();
    const patient = detail?.patient || selected;
    const vitals = detail?.vitals || {};
    const labs = detail?.labs || {};
    const phenotype = detail?.prediction?.latest?.phenotype || {};
    const bp = vitals.sbp && vitals.dbp ? `${Math.round(vitals.sbp)}/${Math.round(vitals.dbp)}` : "--";
    page.innerHTML = `${pageTitle("当前患者状态", "家属端实时关注基础生理特征和趋势变化。")}
      ${state.apiStatus !== "online" ? `<div class="notice">${safeText(state.apiError || "后端暂不可达，当前显示离线 demo 数据。请检查 API 地址和 server.py。")}</div>` : ""}
      <div class="status-hero">
        <div>
          <span class="pill">更新 ${safeText(formatTimestamp(detail?.updated_at || state.lastFamilyRefresh))}</span>
          <h3>${safeText(patient.masked_id || "--")} · ${safeText(patient.bed_no || "--")}</h3>
          <p>${safeText(patient.icu_ward || "--")} / ${safeText(phenotype.family_label || patient.phenotype_name || "--")}。${safeText(phenotype.description || "趋势仅用于帮助理解监护变化，具体病情解释以主管医生为准。")}</p>
        </div>
        <button class="primary" id="refreshFamilyNow">立即更新</button>
      </div>
      <div class="vital-grid">
        ${vitalCard("心率", Math.round(vitals.heart_rate ?? 0) || "--", "bpm", "循环监护", "vitalHeart", "tone-red")}
        ${vitalCard("呼吸", Math.round(vitals.resp_rate ?? 0) || "--", "次/分", "呼吸频率", "vitalResp", "tone-blue")}
        ${vitalCard("脉搏", Math.round(vitals.pulse ?? vitals.heart_rate ?? 0) || "--", "次/分", "外周脉搏", "vitalPulse", "tone-teal")}
        ${vitalCard("血氧", Math.round(vitals.spo2 ?? 0) || "--", "%", "氧合状态", "vitalSpo2", "tone-green")}
        ${vitalCard("血压", bp, "mmHg", `MAP ${Math.round(vitals.map ?? 0) || "--"} mmHg`, "vitalBp", "tone-amber")}
        ${vitalCard("体温", Number(vitals.temperature ?? 0).toFixed(1), "C", `乳酸 ${labs.lactate ?? "--"} mmol/L`, "vitalTemp", "tone-purple")}
      </div>
      <div class="section"><h3>家属摘要</h3><p>当前信息用于帮助理解 ICU 监护趋势，不提供治疗建议，不承诺预后；如心率、呼吸、血氧、血压或体温持续偏离，请以 ICU 医护人员解释为准。</p></div>`;
    $("#refreshFamilyNow").onclick = async () => {
      await refreshSelectedPatientDetail({ force: true });
      renderWorkspace();
    };
    drawVitalCards(detail?.history || []);
  } else if (state.page === "services") {
    let status;
    let deepseek;
    try {
      status = await api("/api/admin/status");
    } catch (_) {
      status = { service: { status: "offline", name: "server.py" }, device: { cpu: { estimated_usage_percent: 0, cores: "--" }, gpu: { available: false, name: "未连接" } }, backend: { llm_configured: false, deepseek_model: "fallback" } };
    }
    try {
      deepseek = await api("/api/config/deepseek");
      state.deepSeekConfig = deepseek;
    } catch (_) {
      deepseek = state.deepSeekConfig || { configured: false, model: status.backend.deepseek_model || "deepseek-chat", base_url: "https://api.deepseek.com/chat/completions", timeout_seconds: "18", api_key_hint: "" };
    }
    page.innerHTML = `${pageTitle("服务监控", "后端连接、CPU/GPU、DeepSeek 和模型运行设备。")}
      <div class="metrics">${metric("后端", status.service.status, status.service.name)}${metric("CPU", `${Math.round(status.device.cpu.estimated_usage_percent)}%`, `${status.device.cpu.cores} cores`)}${metric("GPU", status.device.gpu.available ? "可用" : "未启用", status.device.gpu.name)}${metric("DeepSeek", deepseek.configured ? "已配置" : "Fallback", deepseek.model || status.backend.deepseek_model)}</div>
      <div class="section">
        <h3>DeepSeek 配置</h3>
        <div class="terminal-config-row">
          <input id="deepseekKey" type="password" placeholder="${deepseek.configured ? `已配置 ${escapeHTML(deepseek.api_key_hint || "")}，留空保留原 Key` : "粘贴 DeepSeek API Key"}">
          <input id="deepseekModel" value="${escapeHTML(deepseek.model || "deepseek-chat")}">
          <button class="primary" id="saveDeepSeek">保存</button>
        </div>
        <div class="terminal-config-row">
          <input id="deepseekBaseURL" value="${escapeHTML(deepseek.base_url || "https://api.deepseek.com/chat/completions")}">
          <input id="deepseekTimeout" value="${escapeHTML(deepseek.timeout_seconds || "18")}">
          <button class="secondary" id="clearDeepSeek">清除 Key</button>
        </div>
        <p class="subtitle">${escapeHTML(state.deepSeekStatus || (deepseek.configured ? "保存后家属端下一条消息会调用 DeepSeek。" : "未配置 Key 时家属端使用本地说明模式。"))}</p>
      </div>`;
    $("#saveDeepSeek").onclick = () => saveDeepSeekConfig(false);
    $("#clearDeepSeek").onclick = () => saveDeepSeekConfig(true);
  } else if (state.page === "accounts") {
    let bindings;
    try { bindings = await api("/api/admin/bindings"); } catch (_) { bindings = { mode: "offline-demo", bindings: [{ family_user: "family-demo", patient_ref: demoPatients[0].masked_id }] }; }
    page.innerHTML = `${pageTitle("账号绑定", "后台维护 family 账号与患者绑定。")}<div class="section"><pre>${safeJSON(bindings)}</pre></div>`;
  } else if (state.page === "api") {
    page.innerHTML = `${pageTitle("API 覆盖", "四端共享 server.py API smoke。")}<div class="section"><button class="primary" id="smoke">运行 smoke</button><pre id="smokeOut"></pre></div>`;
    $("#smoke").onclick = async () => {
      try {
        $("#smokeOut").textContent = JSON.stringify({ health: await api("/health"), stats: await api("/api/dashboard/stats"), metadata: await api("/api/model/metadata") }, null, 2);
      } catch (_) {
        $("#smokeOut").textContent = JSON.stringify({ mode: "offline-demo", error: state.apiError }, null, 2);
      }
    };
  } else if (state.page === "audit") {
    let audit;
    try { audit = await api("/api/audit"); } catch (_) { audit = [{ ts: new Date().toISOString(), event: "offline-demo", detail: state.apiError }]; }
    page.innerHTML = `${pageTitle("审计日志", "本地模型、AI、临床和家属问答调用事件。")}<div class="section"><pre>${safeJSON(audit)}</pre></div>`;
  }
}

async function saveDeepSeekConfig(clearKey) {
  const payload = {
    api_key: clearKey ? "" : ($("#deepseekKey")?.value || "").trim(),
    model: ($("#deepseekModel")?.value || "deepseek-chat").trim(),
    base_url: ($("#deepseekBaseURL")?.value || "https://api.deepseek.com/chat/completions").trim(),
    timeout_seconds: ($("#deepseekTimeout")?.value || "18").trim(),
    clear_key: Boolean(clearKey)
  };
  try {
    const result = await api("/api/config/deepseek", { method: "POST", body: JSON.stringify(payload) });
    state.deepSeekConfig = result;
    state.deepSeekStatus = result.configured ? `DeepSeek 已保存：${result.api_key_hint || "已配置"}。请回到家属端继续提问。` : "DeepSeek Key 已清除，家属端将使用本地说明模式。";
  } catch (error) {
    state.deepSeekStatus = `DeepSeek 配置保存失败：${error.message}`;
  }
  renderWorkspace();
}

async function renderRealtimePage(page) {
  try {
    state.realtimeStatus = await api("/api/icu/realtime/status");
  } catch (_) {
    state.realtimeStatus = state.realtimeStatus || { ok: false, total_events: 0, upload: {}, last_event: null };
  }
  const status = state.realtimeStatus || {};
  const upload = status.upload || {};
  const cloudURL = displayCloudBase(state.trainingStatus?.cloud_base_url || state.apiBase || CLOUD_API_BASE);
  page.innerHTML = `${pageTitle("实时 ICU 监护接入", "院内监护时序先写入本地脱敏 JSONL，再上传云端模型服务作为增量训练数据。")}
    <div class="metrics">
      ${metric("本地事件", status.total_events ?? 0, status.storage || "managed-runtime/icu_timeseries.jsonl")}
      ${metric("最近上传", upload.uploaded_events ?? "--", upload.last_upload_at || "未上传")}
      ${metric("云端接收", upload.cloud_accepted ?? "--", upload.training_ready ? "可训练" : "待同步")}
      ${metric("训练入口", "/api/training/command", "continue_training")}
    </div>
    <div class="section">
      <h3>云端模型服务</h3>
      <div class="terminal-config-row">
        <input id="realtimeCloudURL" value="${escapeHTML(cloudURL)}" placeholder="http://100.65.136.96:8788">
        <button class="primary" id="realtimeIngestDemo">写入 Demo 时序</button>
        <button class="primary" id="realtimeUpload">上传云端</button>
      </div>
      <div class="terminal-input">
        <button class="secondary" id="realtimeTrain">启动增量训练</button>
        <button class="secondary" id="realtimeRefresh">刷新状态</button>
      </div>
    </div>
    <div class="split">
      <div class="section"><h3>最近事件</h3><pre class="terminal-output realtime-output">${safeJSON(status.last_event || {})}</pre></div>
      <div class="section"><h3>闭环回显</h3><pre class="terminal-output realtime-output" id="realtimeOutput">${escapeHTML(state.realtimeOutput)}</pre></div>
    </div>`;
  $("#realtimeIngestDemo").onclick = ingestRealtimeDemo;
  $("#realtimeUpload").onclick = uploadRealtimeEvents;
  $("#realtimeTrain").onclick = trainRealtimeEvents;
  $("#realtimeRefresh").onclick = () => renderWorkspace();
}

async function ingestRealtimeDemo() {
  try {
    const demo = await api("/api/icu/realtime/demo");
    const response = await api("/api/icu/realtime/ingest", {
      method: "POST",
      body: JSON.stringify(demo.demo || {}),
      timeoutMs: 12000
    });
    state.realtimeStatus = response.status;
    state.realtimeOutput = JSON.stringify(response, null, 2);
  } catch (_) {
    state.realtimeOutput = `实时数据写入失败：${state.apiError}`;
  }
  renderWorkspace();
}

async function uploadRealtimeEvents() {
  const cloudBaseURL = $("#realtimeCloudURL")?.value || "";
  try {
    const response = await api("/api/icu/realtime/upload", {
      method: "POST",
      body: JSON.stringify({ cloud_base_url: cloudBaseURL, limit: 500 }),
      timeoutMs: 30000
    });
    state.realtimeStatus = response.status;
    state.realtimeOutput = JSON.stringify(response, null, 2);
  } catch (_) {
    state.realtimeOutput = `时序上传失败：${state.apiError}`;
  }
  renderWorkspace();
}

async function trainRealtimeEvents() {
  const cloudBaseURL = $("#realtimeCloudURL")?.value || "";
  try {
    await api("/api/training-terminal/config", {
      method: "POST",
      body: JSON.stringify({ mode: "production", cloud_base_url: cloudBaseURL, params: { source: "icu-realtime", safe_mode: true } }),
      timeoutMs: 20000
    });
    const response = await api("/api/training-terminal/action", {
      method: "POST",
      body: JSON.stringify({ action: "continue_training" }),
      timeoutMs: 30000
    });
    state.trainingStatus = response.status;
    state.realtimeOutput = JSON.stringify(response, null, 2);
  } catch (_) {
    state.realtimeOutput = `增量训练启动失败：${state.apiError}`;
  }
  renderWorkspace();
}

async function renderTrainingPage(page) {
  try {
    state.trainingStatus = await api("/api/training-terminal/status");
  } catch (_) {
    state.trainingStatus = fallbackTrainingStatus();
  }
  const status = state.trainingStatus;
  const metrics = status.metrics || {};
  const params = status.params || {};
  const mode = status.mode || "demo";
  const cloudURL = displayCloudBase(status.cloud_base_url || "");
  const actionButtons = (status.actions?.length ? status.actions : trainingActions.map(([action, title, shortcut]) => ({ action, title, shortcut })))
    .map(item => `<button class="terminal-action" data-training-action="${escapeHTML(item.action)}"><b>${escapeHTML(item.title)}</b><small>${escapeHTML(item.shortcut || "")}</small></button>`)
    .join("");

  page.innerHTML = `${pageTitle("机器学习模型训练终端", "演示模式本地占位运行，生产模式远程对接云端算力服务器。")}
    <div class="metrics">
      ${metric("调用模式", status.mode_label || modeTitle(mode), status.model_profile || "local_demo")}
      ${metric("训练状态", trainingStatusLabel(status.task_status), status.last_action || "initialized")}
      ${metric("Loss", formatMetric(metrics.loss), `epoch ${formatMetric(metrics.epoch, 0)}/${formatMetric(params.epochs, 0)}`)}
      ${metric("Accuracy", formatMetric(metrics.accuracy), `macro_f1 ${formatMetric(metrics.macro_f1)}`)}
    </div>
    <div class="notice">${escapeHTML(status.notice || modeNotice(mode, Boolean(cloudURL)))}</div>
    <div class="section terminal-config">
      <h3>模式与云端地址</h3>
      <div class="terminal-config-row">
        <select id="trainingMode">
          <option value="demo" ${mode === "demo" ? "selected" : ""}>本地演示模型</option>
          <option value="production" ${mode === "production" ? "selected" : ""}>云端生产模型</option>
        </select>
        <input id="trainingCloudURL" value="${escapeHTML(cloudURL)}" placeholder="云端训练服务地址，例如 http://100.65.136.96:8788">
        <button class="primary" id="saveTrainingConfig">保存配置</button>
      </div>
    </div>
    <div class="section">
      <h3>快捷训练操作</h3>
      <div class="terminal-actions">${actionButtons}</div>
    </div>
    <div class="section">
      <h3>自定义训练指令</h3>
      <div class="terminal-input">
        <input id="trainingCommand" placeholder="例如 status、train --resume、show metrics、download artifacts">
        <button class="primary" id="sendTrainingCommand">下发</button>
      </div>
    </div>
    <div class="section">
      <h3>终端实时回显</h3>
      <pre class="terminal-output" id="trainingOutput">${escapeHTML(state.trainingOutput)}</pre>
    </div>`;

  $("#saveTrainingConfig").onclick = saveTrainingConfig;
  $("#sendTrainingCommand").onclick = sendTrainingCommand;
  $("#trainingCommand").addEventListener("keydown", event => {
    if (event.key === "Enter") sendTrainingCommand();
  });
  document.querySelectorAll("[data-training-action]").forEach(button => {
    button.onclick = () => runTrainingAction(button.dataset.trainingAction);
  });
}

function fallbackTrainingStatus() {
  return {
    ok: false,
    mode: "demo",
    mode_label: "本地演示模式",
    model_profile: "local_demo",
    task_status: "offline",
    cloud_base_url: "",
    last_action: "offline",
    updated_at: new Date().toISOString(),
    metrics: { epoch: 0, progress: 0, loss: 0.436, accuracy: 0.842, macro_f1: 0.817 },
    params: { epochs: 20, batch_size: 64, learning_rate: 0.0008 },
    actions: trainingActions.map(([action, title, shortcut]) => ({ action, title, shortcut })),
    notice: state.apiError || "后端暂不可达，训练终端当前只显示离线演示说明。"
  };
}

async function saveTrainingConfig() {
  const mode = $("#trainingMode")?.value || "demo";
  const cloudBaseURL = $("#trainingCloudURL")?.value || "";
  try {
    const status = await api("/api/training-terminal/config", {
      method: "POST",
      body: JSON.stringify({ mode, cloud_base_url: cloudBaseURL }),
      timeoutMs: 20000
    });
    state.trainingStatus = status;
    state.trainingOutput = `[${status.updated_at}] 配置已保存。\n${status.notice}`;
  } catch (_) {
    state.trainingOutput = `配置保存失败：${state.apiError}`;
  }
  renderWorkspace();
}

async function runTrainingAction(action) {
  if (!action) return;
  try {
    const response = await api("/api/training-terminal/action", {
      method: "POST",
      body: JSON.stringify({ action }),
      timeoutMs: 25000
    });
    state.trainingStatus = response.status;
    state.trainingOutput = (response.output || []).join("\n") || JSON.stringify(response, null, 2);
  } catch (_) {
    state.trainingOutput = `训练终端动作失败：${state.apiError}`;
  }
  renderWorkspace();
}

async function sendTrainingCommand() {
  const input = $("#trainingCommand");
  const command = input?.value.trim();
  if (!command) return;
  try {
    const response = await api("/api/training-terminal/command", {
      method: "POST",
      body: JSON.stringify({ command }),
      timeoutMs: 25000
    });
    state.trainingStatus = response.status;
    state.trainingOutput = (response.output || []).join("\n") || JSON.stringify(response, null, 2);
  } catch (_) {
    state.trainingOutput = `训练终端指令失败：${state.apiError}`;
  }
  renderWorkspace();
}

function trainingStatusLabel(value) {
  if (value === "running") return "运行中";
  if (value === "paused") return "已暂停";
  if (value === "synced") return "已同步";
  if (value === "error") return "异常";
  if (value === "offline") return "离线";
  return "待命";
}

function modeTitle(mode) {
  return mode === "production" ? "云端生产模式" : "本地演示模式";
}

function modeNotice(mode, cloudReady) {
  if (mode === "production") {
    return cloudReady ? "生产模式会把训练指令转发到云端算力服务器。" : "生产模式尚未配置云端训练服务地址，训练指令不会被执行。";
  }
  return "演示模式仅使用安装包内置数据和模型占位，不消耗云端算力，适合课程答辩展示。";
}

function formatMetric(value, digits = 3) {
  const number = Number(value);
  if (!Number.isFinite(number)) return value ?? "--";
  return digits === 0 ? String(Math.round(number)) : number.toFixed(digits);
}

async function sendChat() {
  const input = $("#chatInput");
  const text = input.value.trim();
  if (!text) return;
  state.messages.push({ role: "user", text });
  input.value = "";
  try {
    const reply = await api("/api/family/chat", { method: "POST", body: JSON.stringify({ patient_ref: state.selectedPatient?.masked_id, question: text }) });
    state.messages.push({ role: "assistant", text: reply.answer });
  } catch (error) {
    state.messages.push({ role: "assistant", text: "后端暂不可用，请检查 server.py 是否启动。" });
  }
  renderWorkspace();
}

function drawVitalCards(history) {
  const points = Array.isArray(history) && history.length ? history : buildDemoPatientDetail(state.selectedPatient || demoPatients[0]).history;
  drawMiniTrend("vitalHeart", points, "heart_rate", "#c93a4a");
  drawMiniTrend("vitalResp", points, "resp_rate", "#2563eb");
  drawMiniTrend("vitalPulse", points, "pulse", "#008f83");
  drawMiniTrend("vitalSpo2", points, "spo2", "#168047");
  drawMiniTrend("vitalBp", points, "map", "#a46100");
  drawMiniTrend("vitalTemp", points, "temperature", "#6d3fc2");
}

function drawMiniTrend(canvasId, points, key, color) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(180, canvas.clientWidth);
  const height = 96;
  canvas.width = width * dpr;
  canvas.height = height * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, width, height);
  const values = points
    .map(point => ({ hour: Number(point.hour), value: Number(point[key]) }))
    .filter(point => Number.isFinite(point.hour) && Number.isFinite(point.value));
  if (!values.length) return;
  const minHour = Math.min(...values.map(point => point.hour));
  const maxHour = Math.max(...values.map(point => point.hour));
  const minValue = Math.min(...values.map(point => point.value));
  const maxValue = Math.max(...values.map(point => point.value));
  const hourSpan = Math.max(1, maxHour - minHour);
  const valueSpan = Math.max(1, maxValue - minValue);
  ctx.strokeStyle = "rgba(15, 35, 48, .12)";
  ctx.lineWidth = 1;
  for (let y = 18; y < height; y += 24) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(width, y);
    ctx.stroke();
  }
  ctx.strokeStyle = color;
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  values.forEach((point, index) => {
    const x = 8 + ((point.hour - minHour) / hourSpan) * (width - 16);
    const y = height - 14 - ((point.value - minValue) / valueSpan) * (height - 30);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();
  const latest = values[values.length - 1];
  const x = 8 + ((latest.hour - minHour) / hourSpan) * (width - 16);
  const y = height - 14 - ((latest.value - minValue) / valueSpan) * (height - 30);
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(x, y, 3.5, 0, Math.PI * 2);
  ctx.fill();
}

function drawTrend(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * dpr;
  canvas.height = 240 * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, canvas.clientWidth, 240);
  const series = buildTrendSeries();
  const allHours = series.flatMap(trend => trend.points.map(point => point.hour));
  const minHour = Math.min(...allHours, 0);
  const maxHour = Math.max(...allHours, 48);
  const hourSpan = Math.max(1, maxHour - minHour);
  ctx.strokeStyle = "rgba(255,255,255,.12)";
  for (let y = 30; y < 220; y += 38) { ctx.beginPath(); ctx.moveTo(34, y); ctx.lineTo(canvas.clientWidth - 14, y); ctx.stroke(); }
  series.forEach((trend, sidx) => {
    ctx.strokeStyle = trend.color; ctx.lineWidth = 2; ctx.beginPath();
    trend.points.forEach((point, idx) => {
      const x = 36 + ((point.hour - minHour) / hourSpan) * (canvas.clientWidth - 58);
      const y = 220 - point.value * 1.55;
      if (idx === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();
    ctx.fillStyle = trend.color; ctx.fillText(trend.label, 42 + sidx * 70, 22);
  });
}

function buildTrendSeries() {
  const configs = [
    ["HR", "#e62945", 96, 28],
    ["MAP", "#1a66fa", 76, 12],
    ["SpO2", "#2eb857", 94, 4],
    ["Lac x20", "#ffb338", 46, 18]
  ];
  return configs.map(([label, color, base, amp], seriesIndex) => ({
    label,
    color,
    points: normalizeTrendPoints(Array.from({ length: 49 }, (_, hour) => ({
      hour,
      value: base + Math.sin(hour / 5 + seriesIndex) * amp
    })))
  }));
}

function normalizeTrendPoints(points) {
  const latestByHour = new Map();
  points.forEach(point => {
    const hour = Number(point.hour);
    const value = Number(point.value);
    if (Number.isFinite(hour) && Number.isFinite(value)) {
      latestByHour.set(hour, value);
    }
  });
  return Array.from(latestByHour.entries())
    .sort(([leftHour], [rightHour]) => leftHour - rightHour)
    .map(([hour, value]) => ({ hour, value }));
}

function startFamilyAutoRefresh() {
  if (familyRefreshTimer) window.clearInterval(familyRefreshTimer);
  familyRefreshTimer = window.setInterval(async () => {
    if (!state.authenticated || state.role !== "family" || state.page !== "familyStatus") return;
    await refreshSelectedPatientDetail({ force: true });
    if (state.authenticated && state.role === "family" && state.page === "familyStatus") {
      renderWorkspace();
    }
  }, 30000);
}

document.addEventListener("keydown", event => {
  if (!state.authenticated || state.page !== "training") return;
  if (!(event.ctrlKey || event.metaKey)) return;
  const index = Number(event.key);
  if (!Number.isInteger(index) || index < 1 || index > trainingActions.length) return;
  event.preventDefault();
  runTrainingAction(trainingActions[index - 1][0]);
});

renderLogin();
