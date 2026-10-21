const test = require("node:test");
const assert = require("node:assert/strict");
const { loadBackground } = require("./helpers");

const ENDPOINT = "http://127.0.0.1:57643/api";

// ---------- download capture ----------

test("a browser download is sent to MacDM and cancelled in Chrome", async () => {
  const { listeners, calls } = loadBackground({ reply: { ok: true } });
  await listeners.download({ id: 7, url: "https://x.test/a.zip", fileSize: 5000000, filename: "/Users/me/Downloads/a.zip", referrer: "https://x.test/" });

  assert.equal(calls.fetch.length, 1);
  assert.equal(calls.fetch[0].url, ENDPOINT);
  assert.equal(calls.fetch[0].options.method, "POST");
  assert.deepEqual(calls.fetch[0].body, {
    action: "download",
    url: "https://x.test/a.zip",
    sizeBytes: 5000000,
    suggestedFileName: "a.zip",
    sourcePageURL: "https://x.test/",
    headers: { Referer: "https://x.test/" }   // so a protected server accepts MacDM's download
  });
  assert.deepEqual(calls.cancel, [7]);
  assert.deepEqual(calls.erase, [{ id: 7 }]);
});

test("the final URL after redirects is preferred", async () => {
  const { listeners, calls } = loadBackground();
  await listeners.download({ id: 1, url: "https://x.test/redirect", finalUrl: "https://cdn.test/real.zip", fileSize: -1 });
  assert.equal(calls.fetch[0].body.url, "https://cdn.test/real.zip");
});

test("an unknown size (-1) is not sent as a size", async () => {
  const { listeners, calls } = loadBackground();
  await listeners.download({ id: 1, url: "https://x.test/a.zip", fileSize: -1 });
  assert.equal(calls.fetch[0].body.sizeBytes, undefined);
});

test("Chrome keeps the download when MacDM is not running", async () => {
  const { listeners, calls } = loadBackground({ reply: new Error("connection refused") });
  await listeners.download({ id: 3, url: "https://x.test/a.zip", fileSize: 5000000 });
  assert.deepEqual(calls.cancel, []);
});

test("Chrome keeps the download when MacDM reports an error", async () => {
  const { listeners, calls } = loadBackground({ reply: { ok: false, error: "Missing URL" } });
  await listeners.download({ id: 3, url: "https://x.test/a.zip" });
  assert.deepEqual(calls.cancel, []);
});

test("Chrome keeps downloads that MacDM skips (tiny files)", async () => {
  const { listeners, calls } = loadBackground({ reply: { ok: true, skipped: true } });
  await listeners.download({ id: 3, url: "https://x.test/pixel.png", fileSize: 100 });
  assert.deepEqual(calls.cancel, []);
});

test("blob:, data: and file: downloads are left alone", async () => {
  for (const url of ["blob:https://x.test/uuid", "data:text/plain;base64,AAAA", "file:///tmp/a.zip", ""]) {
    const { listeners, calls } = loadBackground();
    await listeners.download({ id: 1, url });
    assert.equal(calls.fetch.length, 0, `${url} should not be sent`);
    assert.deepEqual(calls.cancel, []);
  }
});

// ---------- messages from the page ----------

test("page messages are relayed to MacDM and the reply is returned", async () => {
  const { listeners, calls } = loadBackground({ reply: { ok: true, title: "Video" } });
  let answer;
  const keepOpen = listeners.message({ type: "native", payload: { action: "formats", url: "https://y.test/v" } }, {}, (r) => (answer = r));
  assert.equal(keepOpen, true, "must return true to keep the reply channel open");
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls.fetch[0].body, { action: "formats", url: "https://y.test/v" });
  assert.deepEqual(answer, { ok: true, title: "Video" });
});

test("messages that are not for MacDM are ignored", () => {
  const { listeners, calls } = loadBackground();
  assert.equal(listeners.message({ type: "something-else" }, {}, () => {}), undefined);
  assert.equal(listeners.message(undefined, {}, () => {}), undefined);
  assert.equal(calls.fetch.length, 0);
});

test("when MacDM is unreachable the page gets a friendly error", async () => {
  const { listeners } = loadBackground({ reply: new Error("offline") });
  let answer;
  listeners.message({ type: "native", payload: { action: "formats" } }, {}, (r) => (answer = r));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(answer.ok, false);
  assert.match(answer.error, /MacDM is running|Could not reach MacDM/);
});

// ---------- context menu ----------

test("a 'Send to MacDM' menu item is created for links and media", () => {
  const { listeners, calls } = loadBackground();
  listeners.installed();
  assert.equal(calls.menus.length, 1);
  assert.equal(calls.menus[0].title, "Send to MacDM");
  assert.deepEqual([...calls.menus[0].contexts].sort(), ["audio", "link", "video"]);
});

test("the menu item sends the link as a forced download", async () => {
  const { listeners, calls } = loadBackground();
  listeners.installed();
  const id = calls.menus[0].id;
  listeners.menuClick({ menuItemId: id, linkUrl: "https://x.test/f.pdf" }, { url: "https://x.test/page" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls.fetch[0].body, {
    action: "download", url: "https://x.test/f.pdf", forced: true, sourcePageURL: "https://x.test/page",
    headers: { Referer: "https://x.test/page" }
  });
});

test("the menu item falls back to the media source URL", async () => {
  const { listeners, calls } = loadBackground();
  listeners.installed();
  listeners.menuClick({ menuItemId: calls.menus[0].id, srcUrl: "https://x.test/clip.mp4" }, {});
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.fetch[0].body.url, "https://x.test/clip.mp4");
});

test("other menu items are ignored", async () => {
  const { listeners, calls } = loadBackground();
  listeners.menuClick({ menuItemId: "someone-elses", linkUrl: "https://x.test/f.pdf" }, {});
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.fetch.length, 0);
});
