const fs = require("fs");
const path = require("path");

const source = path.resolve(__dirname, "../../sepsiscare-web-client");
const target = path.resolve(__dirname, "../renderer/web");

function copyRecursive(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyRecursive(from, to);
    } else {
      fs.copyFileSync(from, to);
    }
  }
}

copyRecursive(source, target);
console.log(`Synced ${source} -> ${target}`);
