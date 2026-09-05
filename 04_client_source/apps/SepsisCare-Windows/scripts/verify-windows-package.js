const fs = require("fs");
const path = require("path");

const appDir = path.resolve(__dirname, "..");
const deliveryRoot = path.resolve(appDir, "../../..");

function fail(message) {
  console.error(`not ok: ${message}`);
  process.exit(1);
}

function ok(message) {
  console.log(`ok: ${message}`);
}

function requirePath(label, target) {
  if (!fs.existsSync(target)) fail(`${label} missing: ${target}`);
  ok(`${label}: ${target}`);
}

const packageJsonPath = path.join(appDir, "package.json");
const mainPath = path.join(appDir, "main.js");
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
const resources = packageJson.build && packageJson.build.extraResources;

if (packageJson.version !== "0.9.1") fail(`unexpected package version: ${packageJson.version}`);
if (!Array.isArray(resources)) fail("build.extraResources must be an array");
ok("package metadata");

requirePath("main process", mainPath);
requirePath("bundled Python runtime", path.join(appDir, "vendor/python-3.12.10-embed-amd64/python.exe"));
requirePath("bundled Python license", path.join(appDir, "vendor/python-3.12.10-embed-amd64/LICENSE.txt"));
requirePath("shared web client", path.join(appDir, "renderer/web/index.html"));
requirePath("local backend", path.resolve(appDir, "../sepsiscare-studio/backend/server.py"));
requirePath("model package", path.resolve(deliveryRoot, "03_remote_server_model_package/02_model_deploy_package"));

const resourceTargets = new Set(resources.map(resource => resource.to));
for (const expected of ["web", "python-embed", "backend", "02_model_deploy_package"]) {
  if (!resourceTargets.has(expected)) fail(`extraResources missing target: ${expected}`);
  ok(`extraResources target ${expected}`);
}

const mainSource = fs.readFileSync(mainPath, "utf8");
for (const snippet of [
  "const API_BASE = process.env.SEPSISCARE_API_BASE_URL || LOCAL_API_BASE",
  "python-embed",
  "SEPSISCARE_DEPLOY_ROOT",
  "SEPSISCARE_RUNTIME_ROOT",
  "SEPSISCARE_PUBLIC_API_BASE_URL"
]) {
  if (!mainSource.includes(snippet)) fail(`main.js missing snippet: ${snippet}`);
  ok(`main.js contains ${snippet}`);
}

console.log("windows package verification completed");
