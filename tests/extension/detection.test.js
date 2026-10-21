const test = require("node:test");
const assert = require("node:assert/strict");
const { loadBackground } = require("./helpers");

// The Chrome extension watches network traffic the way IDM does, so the video bar appears for players
// inside embedded frames and for streams whose address has no .mp4 / .m3u8 ending.

const MB = 1024 * 1024;
const header = (name, value) => ({ name, value });
const settle = () => new Promise((resolve) => setImmediate(resolve));

// ---------- recognising media ----------

test("streams are recognised by address or content type", () => {
  const { context } = loadBackground();
  const kind = (details) => (context.classifyMedia(details) || {}).kind;
  assert.equal(kind({ url: "https://cdn.test/master.m3u8?token=abc" }), "hls");
  assert.equal(kind({ url: "https://cdn.test/stream?id=7", contentType: "application/vnd.apple.mpegurl" }), "hls");
  assert.equal(kind({ url: "https://cdn.test/stream?id=7", contentType: "application/x-mpegURL; charset=utf-8" }), "hls");
  assert.equal(kind({ url: "https://cdn.test/manifest.mpd" }), "dash");
  assert.equal(kind({ url: "https://cdn.test/m?id=1", contentType: "application/dash+xml" }), "dash");
});

test("video files are recognised even when the address has no extension", () => {
  const { context } = loadBackground();
  assert.equal(context.classifyMedia({ url: "https://cdn.test/get?id=9&sig=zz", contentType: "video/mp4", size: 5 * MB }).kind, "file");
  assert.equal(context.classifyMedia({ url: "https://cdn.test/v/12345", contentType: "video/webm", size: 5 * MB }).kind, "file");
  assert.equal(context.classifyMedia({ url: "https://cdn.test/a.mp3", contentType: "audio/mpeg", size: 4 * MB }).kind, "file");
});

test("a generic content type counts only when the address looks like media", () => {
  const { context } = loadBackground();
  assert.equal(context.classifyMedia({ url: "https://cdn.test/movie.mkv", contentType: "application/octet-stream", size: 9 * MB }).kind, "file");
  assert.equal(context.classifyMedia({ url: "https://cdn.test/setup.zip", contentType: "application/octet-stream", size: 9 * MB }), null);
});

test("a video of unknown size is offered, a sound of unknown size is not", () => {
  const { context } = loadBackground();
  assert.equal(context.classifyMedia({ url: "https://cdn.test/live", contentType: "video/mp4", size: 0 }).kind, "file");
  assert.equal(context.classifyMedia({ url: "https://cdn.test/click", contentType: "audio/mpeg", size: 0 }), null);
});

test("small files, stream pieces and ordinary pages are not offered", () => {
  const { context } = loadBackground();
  const none = (details) => assert.equal(context.classifyMedia(details), null, JSON.stringify(details));
  none({ url: "https://cdn.test/ping.mp4", contentType: "video/mp4", size: 40 * 1024 });          // too small: an ad or a sound
  none({ url: "https://cdn.test/seg-1.ts", contentType: "video/mp2t", size: 2 * MB });           // piece of a stream
  none({ url: "https://cdn.test/seg-1", contentType: "video/mp2t", size: 2 * MB });
  none({ url: "https://cdn.test/chunk.m4s", contentType: "video/iso.segment", size: 2 * MB });
  none({ url: "https://cdn.test/index.html", contentType: "text/html", size: 3 * MB });
  none({ url: "https://cdn.test/photo.jpg", contentType: "image/jpeg", size: 3 * MB });
  none({ url: "https://cdn.test/app.js", contentType: "application/javascript", size: 3 * MB });
});

test("MacDM's own server, YouTube's chunks and non-web addresses are ignored", () => {
  const { context } = loadBackground();
  const none = (url) => assert.equal(context.classifyMedia({ url, contentType: "video/mp4", size: 5 * MB }), null, url);
  none("http://127.0.0.1:57643/api");
  none("http://localhost:3000/video.mp4");
  none("https://rr3---sn-abc.googlevideo.com/videoplayback?id=1");
  none("https://www.youtube.com/watch?v=1");
  none("blob:https://site.test/uuid");
  none("data:video/mp4;base64,AAAA");
  none("file:///tmp/a.mp4");
  none("not a url");
});

test("the full size comes from Content-Range when a response is partial", () => {
  const { context } = loadBackground();
  assert.equal(context.responseSize({ "content-range": "bytes 0-1023/52428800", "content-length": "1024" }), 52428800);
  assert.equal(context.responseSize({ "content-length": "2048" }), 2048);
  assert.equal(context.responseSize({}), 0);
  assert.equal(context.responseSize({ "content-range": "bytes */*" }), 0);
});

// ---------- finding media on real requests ----------

async function seeVideo(bg, { tabId = 5, requestId = "r1", url = "https://cdn.test/get?id=1", requestHeaders, responseHeaders, statusCode = 200 } = {}) {
  bg.listeners.sendHeaders({
    tabId, requestId, url,
    requestHeaders: requestHeaders || [header("Referer", "https://site.test/watch"), header("Cookie", "session=abc"),
      header("User-Agent", "TestBrowser/1.0"), header("X-Other", "dropped")]
  });
  await bg.listeners.headersReceived({
    tabId, requestId, url, statusCode, frameId: 3,
    responseHeaders: responseHeaders || [header("Content-Type", "video/mp4"), header("Content-Length", String(8 * MB))]
  });
}

test("the extension asks the browser for cookies and referrer, which Chrome only gives on request", () => {
  const bg = loadBackground();
  assert.ok(bg.listeners.sendHeadersExtra.includes("extraHeaders"));
  assert.ok(bg.listeners.sendHeadersExtra.includes("requestHeaders"));
  assert.ok(bg.listeners.headersReceivedExtra.includes("responseHeaders"));
});

test("a video from any frame is stored for its tab, with the browser's Referer, cookie and User-Agent", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  const items = bg.session["media:5"];
  assert.equal(items.length, 1);
  assert.equal(items[0].url, "https://cdn.test/get?id=1");
  assert.equal(items[0].kind, "file");
  assert.equal(items[0].size, 8 * MB);
  assert.deepEqual(items[0].headers, { Referer: "https://site.test/watch", Cookie: "session=abc", "User-Agent": "TestBrowser/1.0" });
});

test("only the headers MacDM needs are kept", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  assert.equal(bg.session["media:5"][0].headers["X-Other"], undefined);
});

test("the page's video bar is told, and the toolbar icon shows how many were found", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  assert.deepEqual(bg.calls.tabMessages, [{ tabId: 5, message: { type: "media-detected" }, options: { frameId: 0 } }]);
  assert.deepEqual(bg.calls.badges.at(-1), { tabId: 5, text: "1" });
});

test("the same address is not listed twice", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { requestId: "a" });
  await seeVideo(bg, { requestId: "b" });
  assert.equal(bg.session["media:5"].length, 1);
});

test("different tabs keep separate lists", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { tabId: 1, url: "https://cdn.test/one" });
  await seeVideo(bg, { tabId: 2, url: "https://cdn.test/two" });
  assert.equal(bg.session["media:1"][0].url, "https://cdn.test/one");
  assert.equal(bg.session["media:2"][0].url, "https://cdn.test/two");
});

test("an HLS stream is found by its playlist", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { url: "https://cdn.test/master.m3u8", responseHeaders: [header("Content-Type", "application/vnd.apple.mpegurl")] });
  assert.equal(bg.session["media:5"][0].kind, "hls");
});

test("partial (206) responses count, using the full file size", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { statusCode: 206, responseHeaders: [header("Content-Type", "video/mp4"), header("Content-Range", "bytes 0-1048575/73400320"), header("Content-Length", "1048576")] });
  assert.equal(bg.session["media:5"][0].size, 73400320);
});

test("errors, redirects and requests that aren't from a tab are ignored", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { statusCode: 404 });
  await seeVideo(bg, { statusCode: 302, requestId: "x" });
  await seeVideo(bg, { tabId: -1, requestId: "y" });
  assert.equal(bg.session["media:5"], undefined);
  assert.equal(bg.session["media:-1"], undefined);
});

test("non-media responses are ignored", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { responseHeaders: [header("Content-Type", "text/html"), header("Content-Length", String(8 * MB))] });
  assert.equal(bg.session["media:5"], undefined);
});

test("a tab keeps at most 30 finds, newest last", async () => {
  const bg = loadBackground();
  for (let i = 0; i < 35; i++) await seeVideo(bg, { requestId: `r${i}`, url: `https://cdn.test/v${i}` });
  const items = bg.session["media:5"];
  assert.equal(items.length, 30);
  assert.equal(items.at(-1).url, "https://cdn.test/v34");
});

// ---------- the page asks for the list ----------

test("the video bar's request for the list is answered from that tab's finds", async () => {
  const bg = loadBackground();
  await seeVideo(bg, { tabId: 5 });
  await seeVideo(bg, { tabId: 6, url: "https://cdn.test/other" });
  let answer;
  const keepOpen = bg.listeners.message({ type: "media-list" }, { tab: { id: 5 } }, (r) => (answer = r));
  assert.equal(keepOpen, true);
  await settle();
  assert.equal(answer.items.length, 1);
  assert.equal(answer.items[0].url, "https://cdn.test/get?id=1");
});

test("a request for the list from outside a tab gets an empty list", () => {
  const bg = loadBackground();
  let answer;
  bg.listeners.message({ type: "media-list" }, {}, (r) => (answer = r));
  assert.equal(JSON.stringify(answer), '{"items":[]}');
});

// ---------- new pages start clean ----------

test("opening a new page in a tab clears its finds and the toolbar count", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  bg.listeners.tabUpdated(5, { status: "loading", url: "https://site.test/next" });
  await settle();
  assert.equal(bg.session["media:5"], undefined);
  assert.deepEqual(bg.calls.badges.at(-1), { tabId: 5, text: "" });
});

test("a page finishing loading, without a new address, keeps the finds", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  bg.listeners.tabUpdated(5, { status: "complete" });
  await settle();
  assert.equal(bg.session["media:5"].length, 1);
});

test("closing a tab forgets its finds", async () => {
  const bg = loadBackground();
  await seeVideo(bg);
  bg.listeners.tabRemoved(5);
  await settle();
  assert.equal(bg.session["media:5"], undefined);
});
