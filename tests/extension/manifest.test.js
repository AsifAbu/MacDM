const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { file, read } = require("./helpers");

const chromeManifest = JSON.parse(read("ChromeExtension/manifest.json"));
const safariManifest = JSON.parse(read("SafariExtension/Resources/manifest.json"));

test("Chrome manifest is Manifest V3 with a service worker", () => {
  assert.equal(chromeManifest.manifest_version, 3);
  assert.equal(chromeManifest.background.service_worker, "background.js");
});

test("Chrome manifest asks only for the permissions it uses", () => {
  assert.deepEqual([...chromeManifest.permissions].sort(), ["contextMenus", "downloads"]);
  // Reach MacDM's local server only, not the whole web.
  assert.deepEqual(chromeManifest.host_permissions, ["http://127.0.0.1/*"]);
});

test("every file the Chrome manifest references exists", () => {
  const referenced = [
    chromeManifest.background.service_worker,
    chromeManifest.action.default_popup,
    ...chromeManifest.content_scripts.flatMap((c) => c.js)
  ];
  for (const name of referenced) {
    assert.ok(fs.existsSync(file("ChromeExtension", name)), `${name} is missing`);
  }
});

test("Safari manifest references files that exist", () => {
  const referenced = [
    ...safariManifest.background.scripts,
    ...safariManifest.content_scripts.flatMap((c) => c.js)
  ];
  for (const name of referenced) {
    assert.ok(fs.existsSync(file("SafariExtension/Resources", name)), `${name} is missing`);
  }
});

test("both extensions use the same MacDM name and version", () => {
  assert.equal(chromeManifest.name, safariManifest.name);
  assert.equal(chromeManifest.version, safariManifest.version);
});

test("Chrome content script runs on all pages, in the top frame's idle phase", () => {
  const [content] = chromeManifest.content_scripts;
  assert.deepEqual(content.matches, ["<all_urls>"]);
  assert.equal(content.run_at, "document_idle");
});

test("the pinned Chrome extension ID matches the ID MacDM trusts", () => {
  const crypto = require("node:crypto");
  assert.ok(chromeManifest.key, "manifest.json needs a `key` so the extension ID is fixed");

  // Chrome derives the ID from the key: first 16 bytes of SHA-256, hex digits mapped 0-9a-f -> a-p.
  const hash = crypto.createHash("sha256").update(Buffer.from(chromeManifest.key, "base64")).digest("hex").slice(0, 32);
  const id = [...hash].map((c) => String.fromCharCode("a".charCodeAt(0) + parseInt(c, 16))).join("");

  const swift = read("MacDM/Services/RequestSecurity.swift");
  const trusted = swift.match(/chromeExtensionIDs: Set<String> = \[([^\]]*)\]/)[1];
  assert.ok(trusted.includes(`"${id}"`), `the app does not trust ${id}; it trusts ${trusted}`);
});
