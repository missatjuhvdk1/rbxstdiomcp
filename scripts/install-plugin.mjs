#!/usr/bin/env node
// Build the Studio plugin from `studio-plugin/` via rojo and drop the
// resulting .rbxm into Studio's Plugins folder so Studio loads it on next
// plugin reload.
//
// Usage:
//   node scripts/install-plugin.mjs               # auto-detect Plugins folder
//   node scripts/install-plugin.mjs <plugins-dir> # explicit Plugins-folder path
//
// Requirements:
//   - rojo on PATH (we pin 7.7.0-rc.1 in studio-plugin/aftman.toml; `aftman install`
//     once in studio-plugin/ provisions it)
//   - wally on PATH and `wally install` has been run inside studio-plugin/ at
//     least once so studio-plugin/Packages/ exists
//
// In Studio after running: open the Plugins tab, right-click the MCP plugin,
// click "Reload" — or just close & reopen Studio.

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT          = join(__dirname, "..");
const PLUGIN_DIR    = join(ROOT, "studio-plugin");
const PROJECT_FILE  = join(PLUGIN_DIR, "rbxstudio-plugin.project.json");
const PACKAGES_DIR  = join(PLUGIN_DIR, "Packages");
const BUILD_OUTPUT  = join(PLUGIN_DIR, "MCPPlugin.rbxm");
const INSTALL_NAME  = "MCPPlugin.rbxm"; // matches the v3.0.0 binary name

// Candidate Plugins-folder paths, in priority order.
const CANDIDATES = [
  process.argv[2],
  // WSL → Windows side
  "/mnt/c/Users/meesv/AppData/Local/Roblox/Plugins",
  // Native Windows
  process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, "Roblox", "Plugins"),
  // macOS
  process.env.HOME && join(process.env.HOME, "Documents", "Roblox", "Plugins"),
  // Linux (Wine / Lutris) — best-guess
  process.env.HOME && join(process.env.HOME, ".wine", "drive_c", "users", process.env.USER || "", "AppData", "Local", "Roblox", "Plugins"),
].filter(Boolean);

function isExistingDir(p) {
  try { return statSync(p).isDirectory(); } catch { return false; }
}

function die(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

if (!existsSync(PROJECT_FILE)) {
  die(`Rojo project not found: ${PROJECT_FILE}`);
}

if (!existsSync(PACKAGES_DIR)) {
  console.error("✗ studio-plugin/Packages/ is missing.");
  console.error("  Run `cd studio-plugin && wally install` once first.");
  process.exit(1);
}

const pluginsDir = CANDIDATES.find(isExistingDir);
if (!pluginsDir) {
  console.error("✗ Could not find Roblox Plugins folder. Tried:");
  for (const c of CANDIDATES) console.error("    " + c);
  console.error("\nPass an explicit path: node scripts/install-plugin.mjs <PATH>");
  process.exit(1);
}

// 1. Build with rojo.
const build = spawnSync(
  "rojo",
  ["build", PROJECT_FILE, "-o", BUILD_OUTPUT],
  { stdio: "inherit" }
);
if (build.error && build.error.code === "ENOENT") {
  die("`rojo` not found on PATH. Install via aftman: `cd studio-plugin && aftman install`.");
}
if (build.status !== 0) {
  die(`rojo build failed (exit ${build.status})`);
}

// 2. Drop into the Plugins folder.
const dest = join(pluginsDir, INSTALL_NAME);
copyFileSync(BUILD_OUTPUT, dest);

const sizeKB = Math.round(statSync(BUILD_OUTPUT).size / 1024);
console.log(`✓ Installed plugin (${sizeKB} KB)`);
console.log(`  → ${dest}`);
console.log("");
console.log("In Studio:");
console.log("  • If MCP plugin is already loaded → Plugins tab → right-click → Reload");
console.log("  • Otherwise just close & reopen Studio");
