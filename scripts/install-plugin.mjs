#!/usr/bin/env node
// Wrap studio-plugin/plugin.luau as an .rbxmx and drop it into Studio's Plugins
// folder so Studio loads the latest source on next plugin reload.
//
// Usage:
//   node scripts/install-plugin.mjs           # auto-detect Plugins folder
//   node scripts/install-plugin.mjs <path>    # explicit Plugins-folder path
//
// In Studio after running: open the Plugins tab, right-click the MCP plugin,
// click "Reload" — or just close & reopen Studio.

import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT     = join(__dirname, "..");
const SOURCE   = join(ROOT, "studio-plugin", "plugin.luau");
const FILENAME = "mcpserver.rbxmx"; // matches the user's existing Local Plugin

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

const pluginsDir = CANDIDATES.find(isExistingDir);
if (!pluginsDir) {
  console.error("✗ Could not find Roblox Plugins folder. Tried:");
  for (const c of CANDIDATES) console.error("    " + c);
  console.error("\nPass an explicit path: node scripts/install-plugin.mjs <PATH>");
  process.exit(1);
}

if (!existsSync(SOURCE)) {
  console.error(`✗ Source file not found: ${SOURCE}`);
  process.exit(1);
}

const luau = readFileSync(SOURCE, "utf8");

// Defensively escape `]]>` in the source so it doesn't terminate the CDATA.
// Standard XML trick: replace ]]> with ]]]]><![CDATA[> which yields ]]> in text.
const safe = luau.replace(/\]\]>/g, "]]]]><![CDATA[>");

const referent = "RBX" + randomBytes(16).toString("hex").toUpperCase();
const guid = [4, 2, 2, 2, 6]
  .map((n) => randomBytes(n).toString("hex").toUpperCase())
  .join("-");

const xml = `<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
\t<External>null</External>
\t<External>nil</External>
\t<Item class="Script" referent="${referent}">
\t\t<Properties>
\t\t\t<ProtectedString name="Source"><![CDATA[${safe}]]></ProtectedString>
\t\t\t<bool name="Disabled">false</bool>
\t\t\t<Content name="LinkedSource"><null></null></Content>
\t\t\t<token name="RunContext">0</token>
\t\t\t<string name="ScriptGuid">{${guid}}</string>
\t\t\t<BinaryString name="AttributesSerialize"></BinaryString>
\t\t\t<SecurityCapabilities name="Capabilities">0</SecurityCapabilities>
\t\t\t<bool name="DefinesCapabilities">false</bool>
\t\t\t<string name="Name">MCPServer</string>
\t\t\t<int64 name="SourceAssetId">-1</int64>
\t\t\t<BinaryString name="Tags"></BinaryString>
\t\t</Properties>
\t</Item>
</roblox>`;

const dest = join(pluginsDir, FILENAME);
writeFileSync(dest, xml, "utf8");

const lines = luau.split("\n").length;
const sizeKB = Math.round(xml.length / 1024);

console.log(`✓ Installed plugin (${lines} lines source, ${sizeKB} KB rbxmx)`);
console.log(`  → ${dest}`);
console.log("");
console.log("In Studio:");
console.log("  • If MCP plugin is already loaded → Plugins tab → right-click → Reload");
console.log("  • Otherwise just close & reopen Studio");
