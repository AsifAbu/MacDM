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
function loadPage({ script = "ChromeExtension/content.js", api = "chrome", withVideo = true, reply = { ok: false, error: "test" } } = {}) {
  const dom = new JSDOM("<!doctype html><body>" + (withVideo ? "<video></video>" : "") + "</body>", {
    url: "https://example.test/watch",
    runScripts: "outside-only",
    pretendToBeVisual: true
  });
  const { window } = dom;
  openPages.push(dom);

  const sent = [];
  window[api] = { runtime: { sendMessage: async (message) => { sent.push(message); return reply; } } };

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
  return { dom, window, sent, bar, panel, downloadButton, closeButton, drag, pointer };
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
