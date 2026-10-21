const test = require("node:test");
const assert = require("node:assert/strict");
const { loadBackground } = require("./helpers");

// "Grab all files on this page": the page's links, as the user sees them and logged in, go to MacDM's Site Grabber.

const tab = { id: 7, url: "https://site.test/watch/1", title: "Episode 1" };
const settle = () => new Promise((resolve) => setImmediate(resolve));
const body = (bg) => bg.calls.fetch.at(-1).body;

test("grabbing sends the page's links with the browser's referrer, identity and cookies", async () => {
  const bg = loadBackground({
    collect: { links: ["https://cdn.test/a.mp4", "https://site.test/b.pdf"] },
    cookies: [{ name: "session", value: "abc" }, { name: "lang", value: "en" }]
  });
  let answer;
  bg.listeners.message({ type: "grab-page" }, { tab }, (r) => (answer = r));
  await settle();

  assert.equal(answer.ok, true);
  const sent = body(bg);
  assert.equal(sent.action, "grab");
  assert.equal(sent.pageURL, "https://site.test/watch/1");
  assert.equal(sent.title, "Episode 1");
  assert.deepEqual(sent.links, ["https://cdn.test/a.mp4", "https://site.test/b.pdf"]);
  assert.deepEqual(sent.headers, { Referer: "https://site.test/watch/1", "User-Agent": "TestBrowser/1.0", Cookie: "session=abc; lang=en" });
});

test("the page itself is asked for its links, in the top frame", async () => {
  const bg = loadBackground({ collect: { links: ["https://cdn.test/a.mp4"] } });
  bg.listeners.message({ type: "grab-page" }, { tab }, () => {});
  await settle();
  assert.deepEqual(bg.calls.tabMessages[0], { tabId: 7, message: { type: "collect-links" }, options: { frameId: 0 } });
});

test("cookies are read for the page's own address only", async () => {
  const bg = loadBackground({ collect: { links: ["https://cdn.test/a.mp4"] } });
  bg.listeners.message({ type: "grab-page" }, { tab }, () => {});
  await settle();
  assert.deepEqual(bg.calls.cookieQueries, ["https://site.test/watch/1"]);
});

test("with no cookies, only the referrer and identity are sent", async () => {
  const bg = loadBackground({ collect: { links: ["https://cdn.test/a.mp4"] }, cookies: [] });
  bg.listeners.message({ type: "grab-page" }, { tab }, () => {});
  await settle();
  assert.equal(body(bg).headers.Cookie, undefined);
  assert.equal(body(bg).headers.Referer, "https://site.test/watch/1");
});

test("the right-click menu does the same thing", async () => {
  const bg = loadBackground({ collect: { links: ["https://cdn.test/a.mp4"] } });
  bg.listeners.installed();
  const grab = bg.calls.menus.find((m) => /Grab all files/.test(m.title));
  bg.listeners.menuClick({ menuItemId: grab.id }, tab);
  await settle();
  assert.equal(body(bg).action, "grab");
  assert.equal(body(bg).pageURL, tab.url);
});

test("a page that was open before the extension was installed asks the user to reload it", async () => {
  const bg = loadBackground({ collect: "fail" });
  let answer;
  bg.listeners.message({ type: "grab-page" }, { tab }, (r) => (answer = r));
  await settle();
  assert.equal(answer.ok, false);
  assert.match(answer.error, /Reload the page/);
  assert.equal(bg.calls.fetch.length, 0, "nothing is sent to MacDM");
});

test("browser pages and missing tabs can't be grabbed", async () => {
  for (const badTab of [{ id: 1, url: "chrome://extensions", title: "x" }, { id: 2, url: "about:blank" }, undefined, {}]) {
    const bg = loadBackground();
    let answer;
    bg.listeners.message({ type: "grab-page" }, { tab: badTab }, (r) => (answer = r));
    await settle();
    assert.equal(answer.ok, false, JSON.stringify(badTab));
    assert.equal(bg.calls.fetch.length, 0);
  }
});

test("MacDM's answer is passed back to the page, including its errors", async () => {
  const bg = loadBackground({ collect: { links: [] }, reply: { ok: false, error: "No downloadable files were found on this page." } });
  let answer;
  bg.listeners.message({ type: "grab-page" }, { tab }, (r) => (answer = r));
  await settle();
  assert.equal(answer.ok, false);
  assert.match(answer.error, /No downloadable files/);
});

test("the page learns that grabbing is available when it asks for the media list", async () => {
  const bg = loadBackground();
  let answer;
  bg.listeners.message({ type: "media-list" }, { tab }, (r) => (answer = r));
  await settle();
  assert.equal(answer.canGrab, true);
});
