const { contextBridge } = require("electron");

contextBridge.exposeInMainWorld("sepsiscarePlatform", {
  platform: "windows",
  version: "0.9.0"
});
