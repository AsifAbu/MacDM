const test = require("node:test");
const { after } = require("node:test");
const assert = require("node:assert/strict");
const { JSDOM } = require("jsdom");
const { read } = require("./helpers");

// content.js polls with setInterval; closing the windows stops those timers.
const openPages = [];
after(() => openPages.forEach((dom) => dom.window.close()));

const VIDEO_RECT = { width: 640, height: 360, top: 100, left: 100, right: 740, bottom: 460, x: 100, y: 100 };

/**
 * Loads content.js into a jsdom page that has one big <video>.
 * The script builds its UI in a closed shadow root, so we force it open to inspect it.
 */
function loadPage({ script = "ChromeExtension/content.js", api = "chrome", withVideo = true, reply = { ok: false, error: "test" }, detectedItems = [], canGrab = false } = {}) {
  const dom = new JSDOM("<!doctype html><body>" + (withVideo ? "<video></video>" : "") + "</body>", {
    url: "https://example.test/watch",
    runScripts: "outside-only",
    pretendToBeVisual: true
  });
  const { window } = dom;
  openPages.push(dom);

  const sent = [];                    // messages meant for MacDM (not the background's media list)
  const pushListeners = [];
  let currentDetected = detectedItems;
  window[api] = {
    runtime: {
      id: "test-extension",
      sendMessage: async (message) => {
        if (message && message.type === "media-list") return { items: currentDetected, canGrab };
        sent.push(message);
        return reply;
      },
      onMessage: { addListener: (fn) => pushListeners.push(fn) }
    }
  };
  // What the background script does when it finds new media: update its list, then tell the page.
  const background = {
    find(items) { currentDetected = items; pushListeners.forEach((fn) => fn({ type: "media-detected" })); },
    // A message from the background script that the page answers (like "collect-links").
    ask(message) { return new Promise((resolve) => pushListeners.forEach((fn) => fn(message, {}, resolve))); }
  };

  // Open the closed shadow root so the test can look inside.
  const attach = window.Element.prototype.attachShadow;
  window.Element.prototype.attachShadow = function (init) {
    window.__root = attach.call(this, { ...init, mode: "open" });
    return window.__root;
  };
  // jsdom has no layout: give the video a size.
  window.HTMLElement.prototype.getBoundingClientRect = function () {
    return this.tagName === "VIDEO" ? VIDEO_RECT : { width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 };
  };

  window.eval(read(script));
  window.dispatchEvent(new window.Event("resize")); // runs updatePosition()

  const root = window.__root;
  const [bar, panel] = root.children;
  const [downloadButton, closeButton] = bar.children;
  const pointer = (type, x, y, target = bar) =>
    target.dispatchEvent(new window.MouseEvent(type, { bubbles: true, button: 0, clientX: x, clientY: y }));
  const drag = (target, from, to) => {
    pointer("pointerdown", from[0], from[1], target);
    window.dispatchEvent(new window.MouseEvent("pointermove", { clientX: to[0], clientY: to[1] }));
    window.dispatchEvent(new window.MouseEvent("pointerup", { clientX: to[0], clientY: to[1] }));
  };
  return { dom, window, sent, bar, panel, downloadButton, closeButton, drag, pointer, background };
}

const px = (value) => parseFloat(value);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("the download bar appears over a page with a video", () => {
  const { bar, downloadButton } = loadPage();
  assert.equal(bar.style.display, "flex");
  assert.match(downloadButton.textContent, /Download this video/);
});

test("no bar on a page without video or media", () => {
  const { bar } = loadPage({ withVideo: false });
  assert.equal(bar.style.display, "none");
});

test("the bar has a small x button to remove it", () => {
  const { closeButton } = loadPage();
  assert.equal(closeButton.textContent, "✕");
  assert.equal(closeButton.title, "Remove");
});

test("clicking x removes the bar, and it stays removed", () => {
  const { bar, closeButton, window } = loadPage();
  closeButton.click();
  assert.equal(bar.style.display, "none");
  window.dispatchEvent(new window.Event("resize"));
  window.dispatchEvent(new window.Event("scroll"));
  assert.equal(bar.style.display, "none");
});

test("removing the bar does not trigger a download request", async () => {
  const { closeButton, sent } = loadPage();
  closeButton.click();
  await tick();
  assert.equal(sent.length, 0);
});

test("dragging moves the bar by the same distance", () => {
  const { bar, drag } = loadPage();
  const left = px(bar.style.left);
  const top = px(bar.style.top);
  drag(bar, [200, 150], [180, 190]);
  assert.equal(px(bar.style.left), left - 20);
  assert.equal(px(bar.style.top), top + 40);
});

test("the bar stays inside the window when dragged far away", () => {
  const { bar, drag, window } = loadPage();
  drag(bar, [200, 150], [-5000, -5000]);
  assert.ok(px(bar.style.left) >= 0);
  assert.ok(px(bar.style.top) >= 0);
  drag(bar, [200, 150], [9000, 9000]);
  assert.ok(px(bar.style.left) <= window.innerWidth);
  assert.ok(px(bar.style.top) <= window.innerHeight);
});

test("a drag does not count as a click on the download button", async () => {
  const { downloadButton, bar, drag, sent } = loadPage();
  drag(downloadButton, [200, 150], [260, 200]);
  downloadButton.click(); // browsers fire a click right after a drag ends
  await tick();
  assert.equal(sent.length, 0, "no formats request should be sent");
  assert.equal(bar.style.display, "flex");
});

test("a plain click on the download button asks MacDM for the qualities", async () => {
  const { downloadButton, sent, panel } = loadPage();
  downloadButton.click();
  await tick();
  assert.equal(panel.style.display, "block");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].type, "native");
  assert.equal(sent[0].payload.action, "formats");
  assert.equal(sent[0].payload.url, "https://example.test/watch");
});

test("the panel has a close x and a drag handle header", async () => {
  const { downloadButton, panel } = loadPage();
  downloadButton.click();
  await tick();
  const header = panel.children[0];
  assert.match(header.textContent, /MacDM/);
  const close = header.querySelector("button");
  assert.equal(close.textContent, "✕");
  close.click();
  assert.equal(panel.style.display, "none");
});

test("the panel can be dragged by its header", async () => {
  const { downloadButton, panel, drag } = loadPage();
  downloadButton.click();
  await tick();
  const left = px(panel.style.left);
  const top = px(panel.style.top);
  drag(panel.children[0], [300, 200], [340, 230]);
  assert.equal(px(panel.style.left), left + 40);
  assert.equal(px(panel.style.top), top + 30);
});

test("an error from MacDM is shown in the panel", async () => {
  const { downloadButton, panel } = loadPage({ reply: { ok: false, error: "yt-dlp was not found." } });
  downloadButton.click();
  await tick();
  assert.match(panel.textContent, /yt-dlp was not found\./);
});

test("quality options from MacDM are listed with Download buttons", async () => {
  const reply = {
    ok: true, title: "Clip", duration: 65, ffmpeg: true,
    options: [
      { label: "1080p", selector: "bv*+ba", sizeBytes: 5242880, audioOnly: false },
      { label: "Audio only", selector: "ba", audioOnly: true }
    ]
  };
  const { downloadButton, panel, sent } = loadPage({ reply });
  downloadButton.click();
  await tick();
  assert.match(panel.textContent, /Clip/);
  assert.match(panel.textContent, /1080p/);
  assert.match(panel.textContent, /5\.0 MB/);

  const buttons = [...panel.querySelectorAll("button")].filter((b) => b.textContent === "Download");
  assert.equal(buttons.length, 2);
  buttons[0].click();
  await tick();
  const request = sent.at(-1).payload;
  assert.equal(request.action, "download_media");
  assert.equal(request.selector, "bv*+ba");
  assert.equal(request.audioOnly, false);
});

test("the Safari script works the same way (uses `browser`)", async () => {
  const { downloadButton, sent, closeButton, bar } = loadPage({ script: "SafariExtension/Resources/content.js", api: "browser" });
  downloadButton.click();
  await tick();
  assert.equal(sent[0].payload.action, "formats");
  closeButton.click();
  assert.equal(bar.style.display, "none");
});

// ---------- media found in network traffic (IDM-style) ----------

const HLS = { url: "https://cdn.test/master.m3u8?t=1", kind: "hls", size: 0, headers: { Referer: "https://player.test/embed/9", Cookie: "s=1" } };
const FILE = { url: "https://cdn.test/get?id=7", kind: "file", size: 5242880, headers: { Referer: "https://player.test/embed/9", "User-Agent": "TestBrowser/1.0" } };

test("the bar appears when the background finds media, even with no video on the page itself", async () => {
  const { bar, window } = loadPage({ withVideo: false, detectedItems: [FILE] });
  await tick();
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(bar.style.display, "flex");
});

test("the bar stays hidden when nothing at all was found", async () => {
  const { bar, window } = loadPage({ withVideo: false, detectedItems: [] });
  await tick();
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(bar.style.display, "none");
});

test("the bar appears as soon as the background reports a new find", async () => {
  const { bar, window, background } = loadPage({ withVideo: false });
  await tick();
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(bar.style.display, "none");

  background.find([FILE]);
  await tick();
  assert.equal(bar.style.display, "flex");
});

test("a file found in network traffic is listed with its size and downloads with the browser's headers", async () => {
  const { downloadButton, panel, sent } = loadPage({ withVideo: false, detectedItems: [FILE], reply: { ok: false, error: "no page support" } });
  await tick();
  downloadButton.click();
  await tick();
  assert.match(panel.textContent, /Detected media on this page/);
  assert.match(panel.textContent, /5\.0 MB/);

  [...panel.querySelectorAll("button")].find((b) => b.textContent === "Download").click();
  await tick();
  const request = sent.at(-1).payload;
  assert.equal(request.action, "download");
  assert.equal(request.url, FILE.url);
  assert.equal(request.forced, true);
  assert.equal(request.headers["User-Agent"], "TestBrowser/1.0");
  assert.equal(request.headers.Referer, "https://player.test/embed/9", "the player's own page, not the outer page");
});

test("a stream found in network traffic is downloaded as a stream, with the browser's headers", async () => {
  const { downloadButton, panel, sent } = loadPage({ withVideo: false, detectedItems: [HLS], reply: { ok: false, error: "no page support" } });
  await tick();
  downloadButton.click();
  await tick();
  assert.match(panel.textContent, /HLS stream/);

  [...panel.querySelectorAll("button")].find((b) => b.textContent === "Download").click();
  await tick();
  const request = sent.at(-1).payload;
  assert.equal(request.action, "download_media");
  assert.equal(request.url, HLS.url);
  assert.equal(request.headers.Cookie, "s=1");
});

test("a find with no recorded headers still sends the page as the Referer", async () => {
  const { downloadButton, panel, sent } = loadPage({ withVideo: false, detectedItems: [{ url: "https://cdn.test/a.mp4", kind: "file", size: 9e6 }], reply: { ok: false, error: "x" } });
  await tick();
  downloadButton.click();
  await tick();
  [...panel.querySelectorAll("button")].find((b) => b.textContent === "Download").click();
  await tick();
  assert.equal(sent.at(-1).payload.headers.Referer, "https://example.test/watch");
});

test("opening the panel still asks MacDM for the page's qualities when media was found", async () => {
  const { downloadButton, sent } = loadPage({ withVideo: false, detectedItems: [FILE] });
  await tick();
  downloadButton.click();
  await tick();
  assert.equal(sent[0].payload.action, "formats");
});

test("a video inside a shadow root is found too", () => {
  const { dom, window, bar } = loadPage({ withVideo: false });
  const host = dom.window.document.createElement("div");
  dom.window.document.body.appendChild(host);
  const root = host.attachShadow({ mode: "open" });
  root.appendChild(dom.window.document.createElement("video"));
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(bar.style.display, "flex");
});

test("a page with no extension support (Safari) just gets no network finds", async () => {
  const { bar, window } = loadPage({ script: "SafariExtension/Resources/content.js", api: "browser", withVideo: false, detectedItems: [] });
  await tick();
  window.dispatchEvent(new window.Event("resize"));
  assert.equal(bar.style.display, "none");
});

// ---------- grabbing every file on the page ----------

test("the page reports every link on it as the user sees it, including media tags, lazy images and shadow DOM", async () => {
  const { dom, background } = loadPage({ withVideo: false });
  const doc = dom.window.document;
  doc.body.innerHTML = `
    <a href="/files/a.zip">a</a> <a href="https://cdn.test/b.pdf#page=2">b</a> <a href="mailto:x@y.test">m</a>
    <a href="javascript:void(0)">j</a> <a href="/files/a.zip">again</a>
    <video src="/v/main.mp4" poster="/v/poster.jpg"><source src="/v/alt.webm"></video>
    <img data-src="/lazy/p.jpg" srcset="/i/small.jpg 480w, /i/big.jpg 1080w">
    <meta property="og:video" content="https://cdn.test/share.mp4">
    <meta property="og:title" content="https://cdn.test/not-media">`;
  const host = doc.createElement("div");
  doc.body.appendChild(host);
  host.attachShadow({ mode: "open" }).innerHTML = `<a href="/in/shadow.mp3">s</a>`;

  const { links } = await background.ask({ type: "collect-links" });
  for (const expected of [
    "https://example.test/files/a.zip", "https://cdn.test/b.pdf", "https://example.test/v/main.mp4",
    "https://example.test/v/poster.jpg", "https://example.test/v/alt.webm", "https://example.test/lazy/p.jpg",
    "https://example.test/i/small.jpg", "https://example.test/i/big.jpg", "https://cdn.test/share.mp4",
    "https://example.test/in/shadow.mp3"
  ]) assert.ok(links.includes(expected), `missing ${expected}`);
  assert.equal(links.filter((u) => u.endsWith("/files/a.zip")).length, 1, "listed once");
  assert.ok(!links.some((u) => /^(mailto|javascript):/.test(u)));
  assert.ok(!links.includes("https://cdn.test/not-media"), "only video/audio sharing tags are read");
  assert.ok(links.every((u) => !u.includes("#")), "fragments are dropped");
});

test("the Grab button is shown only when the extension can send the page's links to MacDM", async () => {
  for (const [canGrab, shown] of [[true, true], [false, false]]) {
    const { downloadButton, panel } = loadPage({ canGrab });
    await tick();
    downloadButton.click();
    await tick();
    const grab = [...panel.querySelectorAll("button")].find((b) => /Grab all files/.test(b.textContent));
    assert.equal(!!grab, shown, `canGrab=${canGrab}`);
  }
});

test("the Grab button is there even when no video was found, so any page can be grabbed", async () => {
  const { downloadButton, panel } = loadPage({ withVideo: false, detectedItems: [FILE], canGrab: true, reply: { ok: false, error: "x" } });
  await tick();
  downloadButton.click();
  await tick();
  assert.ok([...panel.querySelectorAll("button")].some((b) => /Grab all files/.test(b.textContent)));
});

test("clicking Grab asks the background to send the page's files to MacDM, and says so", async () => {
  const { downloadButton, panel, sent } = loadPage({ withVideo: false, detectedItems: [FILE], canGrab: true, reply: { ok: true, count: 12, options: [] } });
  await tick();
  downloadButton.click();
  await tick();
  const grab = [...panel.querySelectorAll("button")].find((b) => /Grab all files/.test(b.textContent));
  grab.click();
  await tick();
  assert.deepEqual(JSON.parse(JSON.stringify(sent.at(-1))), { type: "grab-page" });
  assert.match(grab.textContent, /Opened in MacDM/);
});

test("if MacDM can't take the links, the button says Failed and shows why", async () => {
  const { downloadButton, panel } = loadPage({ canGrab: true, reply: { ok: false, error: "No downloadable files were found on this page." } });
  await tick();
  downloadButton.click();
  await tick();
  const grab = [...panel.querySelectorAll("button")].find((b) => /Grab all files/.test(b.textContent));
  grab.click();
  await tick();
  assert.equal(grab.textContent, "Failed");
  assert.match(grab.title, /No downloadable files/);
  assert.equal(grab.disabled, false, "the user can try again");
});

// ---------- describing detected streams ----------

test("a detected stream shows its resolution, length and size once MacDM has read its playlist", async () => {
  const HLS_ITEM = { url: "https://cdn.test/hls/playlist.m3u8", kind: "hls", size: 0, headers: {} };
  const { downloadButton, panel, sent } = loadPage({
    withVideo: false, detectedItems: [HLS_ITEM],
    reply: { ok: true, height: 1080, duration: 5400, sizeBytes: 3e9, options: [] }
  });
  await tick();
  downloadButton.click();
  await tick();
  await tick();
  assert.ok(sent.some((m) => m.payload && m.payload.action === "stream_info" && m.payload.url === HLS_ITEM.url));
  assert.match(panel.textContent, /HLS stream · 1080p · 1:30:00 · ~2\.8 GB/);
});

test("a page MacDM can't read is a quiet note, not a red error, when a stream was detected", async () => {
  const { downloadButton, panel } = loadPage({
    detectedItems: [{ url: "https://cdn.test/a.m3u8", kind: "hls", size: 0, headers: {} }],
    reply: { ok: false, error: "Unsupported URL: https://x.test/embed/1" }
  });
  await tick();
  downloadButton.click();
  await tick();
  await tick();
  assert.doesNotMatch(panel.textContent, /Unsupported URL/);
  assert.match(panel.textContent, /Download what was detected below/);
});

test("with nothing detected, the page's own error is still shown", async () => {
  const { downloadButton, panel } = loadPage({ reply: { ok: false, error: "Unsupported URL: https://x.test/e" } });
  await tick();
  downloadButton.click();
  await tick();
  assert.match(panel.textContent, /Unsupported URL/);
});

test("a failed Grab says why, in the panel", async () => {
  const { downloadButton, panel } = loadPage({ withVideo: false, detectedItems: [FILE], canGrab: true, reply: { ok: false, error: "No downloadable files were found on this page." } });
  await tick();
  downloadButton.click();
  await tick();
  [...panel.querySelectorAll("button")].find((b) => /Grab all files/.test(b.textContent)).click();
  await tick();
  assert.match(panel.textContent, /No downloadable files were found/);
});

// ---------- after the extension is reloaded ----------

test("a script left in an open page after the extension was reloaded goes quiet instead of throwing", async () => {
  const { dom, background } = loadPage({ withVideo: true });
  const win = dom.window;
  const api = win.chrome.runtime;
  await tick();
  assert.ok(win.document.documentElement.contains(win.__root.host), "the bar is there while the extension is alive");

  // What Chrome does to the old script: the extension id disappears and every call throws.
  api.id = undefined;
  let calls = 0;
  api.sendMessage = () => { calls++; throw new Error("Extension context invalidated."); };

  assert.doesNotThrow(() => background.find([]));
  await tick();
  assert.equal(calls, 0, "it does not call the dead extension");
  assert.ok(!win.document.documentElement.contains(win.__root.host), "its bar is removed");
});

test("clicking Download in an orphaned page explains what to do", async () => {
  const { dom, downloadButton, panel } = loadPage({ detectedItems: [FILE] });
  await tick();
  downloadButton.click();
  await tick();
  dom.window.chrome.runtime.id = undefined;
  const row = [...panel.querySelectorAll("button")].find((b) => b.textContent === "Download");
  assert.ok(row, "the detected file has a Download button");
  row.click();
  await tick();
  assert.match(row.title, /Reload this page/);
});

// ---------- naming a detected file ----------

async function openAndClickDownload({ item, title }) {
  const page = loadPage({ withVideo: false, detectedItems: [item], reply: { ok: true, options: [] } });
  if (title !== undefined) page.dom.window.document.title = title;
  await tick();
  page.downloadButton.click();
  await tick();
  const row = [...page.panel.querySelectorAll("button")].find((b) => b.textContent === "Download");
  assert.ok(row, "the detected file has a Download button");
  row.click();
  await tick();
  const sentDownload = page.sent.map((m) => m.payload).filter(Boolean).find((p) => p.action === "download");
  return { page, sentDownload };
}

const HASH_URL = "https://fast-stream.test/92af9fb0-82fb501e-4d796360-c5844d51";

test("a video link that ends in a hash is saved under the page's title, with .mp4 from its content type", async () => {
  const { page, sentDownload } = await openAndClickDownload({
    item: { url: HASH_URL, kind: "file", size: 9e8, contentType: "video/mp4", headers: {} }, title: "My Movie"
  });
  assert.equal(sentDownload.suggestedFileName, "My Movie.mp4");
  assert.match(page.panel.textContent, /My Movie\.mp4/, "the panel shows the same name");
});

test("the ending follows the content type", async () => {
  for (const [type, ending] of [["video/webm", "webm"], ["video/x-matroska", "mkv"], ["audio/mpeg", "mp3"], ["audio/mp4", "m4a"], ["video/something-new", "mp4"]]) {
    const { sentDownload } = await openAndClickDownload({
      item: { url: HASH_URL, kind: "file", size: 9e8, contentType: type, headers: {} }, title: "Clip"
    });
    assert.equal(sentDownload.suggestedFileName, `Clip.${ending}`, type);
  }
});

test("characters a file name can't hold are removed from the page title", async () => {
  const { sentDownload } = await openAndClickDownload({
    item: { url: HASH_URL, kind: "file", size: 9e8, contentType: "video/mp4", headers: {} }, title: 'Part 1/2: "Best" <show>? | Site'
  });
  assert.equal(sentDownload.suggestedFileName, "Part 1 2 Best show Site.mp4");
});

test("a link that already ends in a media file name keeps it", async () => {
  const { sentDownload } = await openAndClickDownload({
    item: { url: "https://cdn.test/files/episode-04.mkv", kind: "file", size: 9e8, contentType: "video/x-matroska", headers: {} }, title: "Some Page"
  });
  assert.equal(sentDownload.suggestedFileName, "episode-04.mkv");
});

test("without a page title or a known type, the link's own name is used rather than something invented", async () => {
  const noTitle = await openAndClickDownload({
    item: { url: HASH_URL, kind: "file", size: 9e8, contentType: "video/mp4", headers: {} }, title: ""
  });
  assert.equal(noTitle.sentDownload.suggestedFileName, "92af9fb0-82fb501e-4d796360-c5844d51.mp4");
  const noType = await openAndClickDownload({
    item: { url: HASH_URL, kind: "file", size: 9e8, contentType: "", headers: {} }, title: "My Movie"
  });
  assert.equal(noType.sentDownload.suggestedFileName, "92af9fb0-82fb501e-4d796360-c5844d51");
});

// ---------- the "Choose quality" list: quality (+ grey detail) | resolution | size | Download ----------

// Each row comes back as [name, grey line, resolution, size, button].
async function openQualityList(options) {
  const reply = { ok: true, title: "Clip", duration: 65, ffmpeg: true, options };
  const page = loadPage({ reply });
  page.downloadButton.click();
  await tick();
  const rows = [...page.panel.querySelectorAll("button")]
    .filter((b) => b.textContent === "Download")
    .map((b) => {
      const [quality, ...rest] = [...b.parentElement.children];
      const [name, sub] = [...quality.children].map((part) => part.textContent);
      return [name, sub || "", ...rest.map((cell) => cell.textContent)];
    });
  return { ...page, rows };
}

test("each quality row shows a name with its height in grey under it, then pixel size, file size and Download", async () => {
  const { rows } = await openQualityList([
    { label: "1080p", selector: "s1", sizeBytes: 90_400_000, audioOnly: false, width: 1920, height: 1080 },
    { label: "720p", selector: "s2", sizeBytes: 33_000_000, audioOnly: false, width: 1280, height: 720 },
    { label: "360p", selector: "s3", sizeBytes: 20_000_000, audioOnly: false, width: 640, height: 360 },
    { label: "144p", selector: "s4", sizeBytes: 11_000_000, audioOnly: false, width: 256, height: 144 }
  ]);
  assert.deepEqual(rows, [
    ["Full HD", "1080p", "1920 × 1080", "86.2 MB", "Download"],
    ["HD", "720p", "1280 × 720", "31.5 MB", "Download"],
    ["Low", "360p", "640 × 360", "19.1 MB", "Download"],
    ["Low", "144p", "256 × 144", "10.5 MB", "Download"]
  ]);
});

test("the grey line is small and grey, under the name", async () => {
  const { panel } = await openQualityList([{ label: "1080p", selector: "s", sizeBytes: 1e8, audioOnly: false, width: 1920, height: 1080 }]);
  const button = [...panel.querySelectorAll("button")].find((b) => b.textContent === "Download");
  const [name, sub] = [...button.parentElement.children[0].children];
  assert.equal(name.textContent, "Full HD");
  assert.equal(sub.textContent, "1080p");
  assert.equal(sub.style.color, "rgb(154, 160, 166)");
  assert.equal(sub.style.fontSize, "11px");
});

test("the audio row shows the audio quality under its name", async () => {
  const { rows } = await openQualityList([
    { label: "Audio only", selector: "a1", sizeBytes: 8_500_000, audioOnly: true, detail: "AAC · 129 kbps" }
  ]);
  assert.deepEqual(rows[0], ["Audio only", "AAC · 129 kbps", "—", "8.1 MB", "Download"]);
});

test("an audio row with no known quality has no grey line, and nothing is invented", async () => {
  const { rows } = await openQualityList([{ label: "Audio only", selector: "a", sizeBytes: 8_500_000, audioOnly: true }]);
  assert.deepEqual(rows[0], ["Audio only", "", "—", "8.1 MB", "Download"]);
});

test("the list has a heading row: Quality, Resolution, Size", async () => {
  const { panel } = await openQualityList([{ label: "720p", selector: "s", sizeBytes: 1e7, audioOnly: false, width: 1280, height: 720 }]);
  const heading = [...panel.querySelectorAll("div")].find((d) => d.children.length === 4 && /^Quality$/.test(d.children[0].textContent));
  assert.ok(heading, "the heading row exists");
  assert.deepEqual([...heading.children].map((c) => c.textContent), ["Quality", "Resolution", "Size", ""]);
});

test("names follow the shorter side, so a vertical video is named like a wide one", async () => {
  const sizes = [[7680, 4320, "8K"], [3840, 2160, "4K"], [2560, 1440, "2K"], [1920, 1080, "Full HD"], [1280, 720, "HD"],
    [854, 480, "SD"], [640, 360, "Low"], [256, 144, "Low"], [1080, 1920, "Full HD"], [720, 1280, "HD"]];
  const { rows } = await openQualityList(sizes.map(([width, height], i) => ({
    label: `${height}p`, selector: `s${i}`, sizeBytes: 1e7, audioOnly: false, width, height
  })));
  assert.deepEqual(rows.map((r) => r[0]), sizes.map((s) => s[2]));
  assert.equal(rows[8][2], "1080 × 1920", "the real pixel size is shown as MacDM sent it");
  assert.equal(rows[8][1], "1080p", "the grey line uses the shorter side too, so it matches the name");
  assert.equal(rows[9][1], "720p");
});

test("a size MacDM doesn't know shows a dash, not blank", async () => {
  const { rows } = await openQualityList([{ label: "720p", selector: "s", audioOnly: false, width: 1280, height: 720 }]);
  assert.deepEqual(rows[0], ["HD", "720p", "1280 × 720", "—", "Download"]);
});

test("an older MacDM that sends no pixel size still shows the name and the height", async () => {
  const { rows } = await openQualityList([{ label: "1080p", selector: "s", sizeBytes: 5242880, audioOnly: false }]);
  assert.deepEqual(rows[0], ["Full HD", "1080p", "—", "5.0 MB", "Download"]);
});

test("Best available has no resolution or grey line to show", async () => {
  const { rows } = await openQualityList([{ label: "Best available", selector: "b/bv*+ba", audioOnly: false }]);
  assert.deepEqual(rows[0], ["Best available", "", "—", "—", "Download"]);
});

test("clicking a quality's Download still sends exactly that quality's selector", async () => {
  const { panel, sent } = await openQualityList([
    { label: "1080p", selector: "bv*[height<=1080]+ba", sizeBytes: 1e8, audioOnly: false, width: 1920, height: 1080 },
    { label: "Audio only", selector: "ba[ext=m4a]/ba/b", sizeBytes: 8e6, audioOnly: true, detail: "AAC · 129 kbps" }
  ]);
  const buttons = [...panel.querySelectorAll("button")].filter((b) => b.textContent === "Download");
  buttons[1].click();
  await tick();
  const request = sent.at(-1).payload;
  assert.equal(request.action, "download_media");
  assert.equal(request.selector, "ba[ext=m4a]/ba/b");
  assert.equal(request.audioOnly, true);
  assert.equal(buttons[1].textContent, "Added ✓");
});
