const test = require("node:test");
const assert = require("node:assert/strict");
const { loadBackground } = require("./helpers");

// Looking up a page's qualities and downloading a video carry the sign-in of the page the user is on, so sites
// that check it (YouTube's "confirm you're not a bot") accept the request. Nothing is stored by the extension.

const settle = () => new Promise((resolve) => setImmediate(resolve));
const cookie = (over = {}) => ({ domain: ".youtube.com", path: "/", name: "SID", value: "abc123", secure: true, httpOnly: true, expirationDate: 1900000000.7, ...over });
const send = (bg, payload) => { let answer; bg.listeners.message({ type: "native", payload }, { tab: { id: 1 } }, (r) => (answer = r)); return () => answer; };
const body = (bg) => bg.calls.fetch.at(-1).body;

test("a quality lookup carries the page's cookies", async () => {
  const bg = loadBackground({ cookies: [cookie(), cookie({ name: "HSID", value: "xyz", httpOnly: false, expirationDate: undefined })] });
  send(bg, { action: "formats", url: "https://www.youtube.com/watch?v=1", referer: "https://www.youtube.com/watch?v=1" });
  await settle();
  const sent = body(bg);
  assert.equal(sent.action, "formats");
  assert.equal(sent.cookies.length, 2);
  assert.deepEqual(sent.cookies[0], { domain: ".youtube.com", path: "/", secure: true, httpOnly: true, expires: 1900000000, name: "SID", value: "abc123" });
  assert.equal(sent.cookies[1].expires, 0, "a session cookie has no expiry");
});

test("downloading a video carries them too", async () => {
  const bg = loadBackground({ cookies: [cookie({ domain: "site.test" })] });
  send(bg, { action: "download_media", url: "https://site.test/watch/1", selector: "b" });
  await settle();
  assert.equal(body(bg).cookies.length, 1);
});

test("YouTube's Google sign-in is read as well", async () => {
  const bg = loadBackground({ cookies: [cookie()] });
  send(bg, { action: "formats", url: "https://www.youtube.com/watch?v=1" });
  await settle();
  assert.deepEqual(bg.calls.cookieQueries, ["https://www.youtube.com/watch?v=1", "https://www.google.com/", "https://accounts.google.com/"]);
});

test("another site gets only its own cookies read", async () => {
  const bg = loadBackground({ cookies: [cookie({ domain: "site.test" })] });
  send(bg, { action: "formats", url: "https://site.test/watch/1" });
  await settle();
  assert.deepEqual(bg.calls.cookieQueries, ["https://site.test/watch/1"]);
});

test("ordinary file downloads and other messages never read cookies", async () => {
  const bg = loadBackground({ cookies: [cookie()] });
  send(bg, { action: "download", url: "https://site.test/a.zip" });
  send(bg, { action: "stream_info", url: "https://cdn.test/a.m3u8" });
  await settle();
  assert.deepEqual(bg.calls.cookieQueries, []);
  assert.equal(bg.calls.fetch.every((call) => call.body.cookies === undefined), true);
});

test("no cookies means no cookies field, and the request still goes through", async () => {
  const bg = loadBackground({ cookies: [] });
  const answer = send(bg, { action: "formats", url: "https://site.test/watch/1" });
  await settle();
  assert.equal("cookies" in body(bg), false);
  assert.equal(answer().ok, true);
});

test("a page that is not a web page gets none, and a cookie failure does not stop the request", async () => {
  const bg = loadBackground({ cookies: [cookie()] });
  send(bg, { action: "formats", url: "file:///etc/passwd" });
  await settle();
  assert.deepEqual(bg.calls.cookieQueries, []);

  const failing = loadBackground({ cookies: "fail" });
  const answer = send(failing, { action: "formats", url: "https://site.test/watch/1" });
  await settle();
  assert.equal(answer().ok, true);
  assert.equal("cookies" in body(failing), false);
});

test("at most 400 cookies are sent", async () => {
  const many = Array.from({ length: 700 }, (_, i) => cookie({ name: `c${i}`, domain: "site.test" }));
  const bg = loadBackground({ cookies: many });
  send(bg, { action: "formats", url: "https://site.test/watch/1" });
  await settle();
  assert.equal(body(bg).cookies.length, 400);
});
