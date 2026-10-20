const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { read } = require("./helpers");

// The Chrome content script is generated from the Safari one by swapping
// `browser.runtime` for `chrome.runtime`. This catches the two drifting apart.
test("Chrome content.js is the Safari content.js with only the API name swapped", () => {
  const safari = read("SafariExtension/Resources/content.js");
  const chrome = read("ChromeExtension/content.js");
  assert.equal(chrome, safari.replaceAll("browser.runtime", "chrome.runtime"));
});

test("Chrome content.js uses no Safari-only `browser` API", () => {
  assert.doesNotMatch(read("ChromeExtension/content.js"), /\bbrowser\./);
});

for (const name of [
  "ChromeExtension/background.js",
  "ChromeExtension/content.js",
  "SafariExtension/Resources/background.js",
  "SafariExtension/Resources/content.js"
]) {
  test(`${name} is valid JavaScript`, () => {
    assert.doesNotThrow(() => new vm.Script(read(name), { filename: name }));
  });
}
