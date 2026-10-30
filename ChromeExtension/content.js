// MacDM content script: IDM-style "Download this video" bar.
//
// - Shows a bar in the top-right corner of the main <video> on the page.
// - Clicking it asks MacDM (yt-dlp) for the available qualities and lists them.
// - Also sniffs direct media / HLS requests so non-YouTube sites work too.
//
// DOM is built with createElement and inline CSSOM styles only: many sites
// (YouTube included) enforce Trusted Types / strict CSP that block innerHTML
// and inline <style> text.

(() => {
  if (window.top !== window) return; // top frame only
  if (window.__macdmInjected) return;
  window.__macdmInjected = true;

  const MEDIA_RE = /\.(m3u8|mpd|mp4|webm|m4v|mov|mp3|m4a|aac|flac)(\?|#|$)/i;
  const STREAM_RE = /\.(m3u8|mpd)(\?|#|$)/i;
  const SKIP_HOSTS = /(googlevideo\.com|doubleclick\.net|googleadservices\.com)/i;

  const sniffed = new Map(); // url -> { url, stream }
  let detected = []; // media the extension's background found in network traffic (any frame): { url, kind, size, headers }
  let canGrab = false; // true when the background script can send this page's links to MacDM's Site Grabber
  let panelOpen = false;
  let requestToken = 0;
  let lastFormatsURL = null;
  let lastFormats = null;
  let lastFormatsFailure = null;   // why the page address couldn't be read, kept so a redraw doesn't lose it
  let barDismissed = false; // user removed the bar with its x button
  const barOffset = { x: 0, y: 0 };   // user drag offsets
  const panelOffset = { x: 0, y: 0 };

  // ---------- messaging ----------

  // When the extension is reloaded or updated, Chrome leaves the old script running in pages that were already
  // open. Its connection to the extension is gone and every call throws "Extension context invalidated", so
  // such a script stops its timers and removes its bar; a fresh script loads with the next page load.
  const timers = [];

  function extensionAlive() {
    try { return !!chrome.runtime.id; } catch (_) { return false; }
  }

  function retire() {
    timers.forEach(clearInterval);
    host.remove();
  }

  /** setInterval that stops everything once the extension behind this script is gone. */
  function every(callback, milliseconds) {
    timers.push(setInterval(() => {
      if (!extensionAlive()) { retire(); return; }
      callback();
    }, milliseconds));
  }

  function native(payload) {
    if (!extensionAlive()) {
      retire();
      return Promise.resolve({ ok: false, error: "MacDM's extension was updated. Reload this page." });
    }
    return chrome.runtime
      .sendMessage({ type: "native", payload })
      .then((reply) => reply || { ok: false, error: "No reply from MacDM." })
      .catch((error) => ({ ok: false, error: String((error && error.message) || error) }));
  }

  // Media the background script found by watching network traffic. Safari's background script doesn't
  // do this, so the reply is simply empty there.
  function refreshDetected() {
    if (!extensionAlive()) { retire(); return Promise.resolve(); }
    return chrome.runtime.sendMessage({ type: "media-list" })
      .then((reply) => {
        const items = reply && Array.isArray(reply.items) ? reply.items : [];
        const grabAvailable = !!(reply && reply.canGrab);
        const changed = items.length !== detected.length || grabAvailable !== canGrab;
        detected = items;
        canGrab = grabAvailable;
        if (changed) {
          updatePosition();
          if (panelOpen) render({ formats: currentFormats() });
        }
      })
      .catch(() => {});
  }

  // Every link on this page as the user sees it (after scripts ran), including inside shadow DOM.
  function collectLinks() {
    const urls = new Set();
    function add(raw) {
      if (!raw || /^(javascript|mailto|tel|data|blob):/i.test(raw)) return;
      try {
        const url = new URL(raw, location.href);
        if (url.protocol === "http:" || url.protocol === "https:") { url.hash = ""; urls.add(url.href); }
      } catch (_) { /* not an address */ }
    }
    function scan(root) {
      for (const node of root.querySelectorAll("a[href], video, audio, source, img, link[href], [data-src], [data-url], [data-video-url], meta[content]")) {
        add(node.getAttribute("href")); add(node.getAttribute("src")); add(node.getAttribute("data-src"));
        add(node.getAttribute("data-url")); add(node.getAttribute("data-video-url")); add(node.getAttribute("poster"));
        const srcset = node.getAttribute("srcset");
        if (srcset) for (const part of srcset.split(",")) add(part.trim().split(/\s+/)[0]);
        const property = (node.getAttribute("property") || node.getAttribute("name") || "").toLowerCase();
        if (node.tagName === "META" && /og:(video|audio)|twitter:player:stream/.test(property)) add(node.getAttribute("content"));
      }
      for (const node of root.querySelectorAll("*")) if (node.shadowRoot) scan(node.shadowRoot);
    }
    scan(document);
    return [...urls].slice(0, 5000);
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message) return;
    if (message.type === "media-detected") refreshDetected();
    if (message.type === "collect-links") sendResponse({ links: collectLinks() });
  });

  // ---------- small DOM helpers ----------

  function el(tag, style, text) {
    const node = document.createElement(tag);
    if (style) Object.assign(node.style, style);
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function formatBytes(bytes) {
    if (!bytes) return "";
    const units = ["B", "KB", "MB", "GB"];
    let value = bytes;
    let i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
    return `${value.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
  }

  function formatDuration(seconds) {
    if (!seconds) return "";
    const s = Math.round(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = String(s % 60).padStart(2, "0");
    return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
  }

  // ---------- UI ----------

  const host = el("div", { position: "fixed", top: "0", left: "0", width: "0", height: "0", zIndex: "2147483647" });
  const root = host.attachShadow({ mode: "closed" });

  const FONT = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif";

  const bar = el("div", {
    position: "fixed", display: "none", alignItems: "center",
    borderRadius: "6px", background: "#1a73e8", cursor: "grab",
    boxShadow: "0 2px 8px rgba(0,0,0,.45)", userSelect: "none"
  });
  const barButton = el("button", {
    display: "flex", alignItems: "center", gap: "6px", padding: "6px 6px 6px 12px",
    border: "none", background: "transparent", cursor: "pointer",
    color: "#fff", font: `600 13px ${FONT}`
  }, "⬇ Download this video");
  barButton.addEventListener("click", (e) => { e.stopPropagation(); togglePanel(); });
  const barClose = el("button", {
    padding: "6px 10px 6px 6px", border: "none", background: "transparent",
    cursor: "pointer", color: "#fff", opacity: "0.8", font: `600 13px ${FONT}`
  }, "✕");
  barClose.title = "Remove";
  barClose.addEventListener("click", (e) => {
    e.stopPropagation();
    barDismissed = true;
    closePanel();
    updatePosition();
  });
  bar.appendChild(barButton);
  bar.appendChild(barClose);

  const panel = el("div", {
    position: "fixed", display: "none", width: "390px", maxHeight: "420px", overflowY: "auto",
    background: "#202124", color: "#e8eaed", borderRadius: "8px", padding: "12px",
    font: `13px ${FONT}`, boxShadow: "0 6px 24px rgba(0,0,0,.55)", boxSizing: "border-box"
  });
  panel.addEventListener("click", (e) => e.stopPropagation());

  // Lets the user drag `node` around; the movement accumulates in `offset`.
  // A drag swallows the click that follows it so buttons don't fire.
  function makeDraggable(node, offset) {
    node.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const startX = e.clientX, startY = e.clientY;
      const baseX = offset.x, baseY = offset.y;
      let dragging = false;
      const move = (ev) => {
        const dx = ev.clientX - startX, dy = ev.clientY - startY;
        if (!dragging && Math.hypot(dx, dy) < 4) return;
        dragging = true;
        offset.x = baseX + dx;
        offset.y = baseY + dy;
        updatePosition();
      };
      const up = () => {
        window.removeEventListener("pointermove", move, true);
        window.removeEventListener("pointerup", up, true);
        if (dragging) {
          const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
          node.addEventListener("click", swallow, { capture: true, once: true });
          setTimeout(() => node.removeEventListener("click", swallow, true), 0);
        }
      };
      window.addEventListener("pointermove", move, true);
      window.addEventListener("pointerup", up, true);
    });
  }
  makeDraggable(bar, barOffset);

  root.appendChild(bar);
  root.appendChild(panel);
  document.documentElement.appendChild(host);

  // ---------- positioning ----------

  // Every <video> on the page, including ones inside (open) shadow DOM, which querySelectorAll skips.
  function allVideos(root = document, found = []) {
    for (const video of root.querySelectorAll("video")) found.push(video);
    for (const node of root.querySelectorAll("*")) {
      if (node.shadowRoot) allVideos(node.shadowRoot, found);
    }
    return found;
  }

  function findMainVideo() {
    let best = null;
    let bestArea = 0;
    for (const video of allVideos()) {
      const r = video.getBoundingClientRect();
      const visible = r.width > 200 && r.height > 100 && r.bottom > 0 && r.top < window.innerHeight;
      const area = r.width * r.height;
      if (visible && area > bestArea) { best = video; bestArea = area; }
    }
    return best;
  }

  function isYouTubeWatch() {
    return /(^|\.)youtube\.com$/.test(location.hostname) && /^\/(watch|shorts)/.test(location.pathname);
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(value, max));
  }

  function updatePosition() {
    const video = findMainVideo();
    const hasMedia = video || sniffed.size > 0 || detected.length > 0;
    if (!hasMedia || barDismissed) {
      bar.style.display = "none";
      closePanel();
      return;
    }
    bar.style.display = "flex";
    const barWidth = bar.offsetWidth || 200;
    const barHeight = bar.offsetHeight || 30;
    let top, left;
    if (video) {
      const r = video.getBoundingClientRect();
      top = Math.max(r.top + 10, 10);
      left = Math.max(Math.min(r.right - barWidth - 10, window.innerWidth - barWidth - 10), 10);
    } else {
      top = 12;
      left = Math.max(window.innerWidth - barWidth - 12, 10);
    }
    bar.style.top = `${clamp(top + barOffset.y, 0, window.innerHeight - barHeight)}px`;
    bar.style.left = `${clamp(left + barOffset.x, 0, window.innerWidth - barWidth)}px`;

    const barRect = bar.getBoundingClientRect();
    const panelTop = barRect.bottom + 6 + panelOffset.y;
    const panelLeft = Math.max(Math.min(barRect.right - 390, window.innerWidth - 400), 10) + panelOffset.x;
    panel.style.top = `${clamp(panelTop, 0, window.innerHeight - 40)}px`;
    panel.style.left = `${clamp(panelLeft, 0, window.innerWidth - 100)}px`;
  }

  every(updatePosition, 700);
  window.addEventListener("scroll", updatePosition, { passive: true });
  window.addEventListener("resize", updatePosition);
  document.addEventListener("click", closePanel);

  // ---------- panel ----------

  function togglePanel() {
    panelOpen ? closePanel() : openPanel();
  }

  function closePanel() {
    panelOpen = false;
    panel.style.display = "none";
  }

  function openPanel() {
    panelOpen = true;
    panel.style.display = "block";
    updatePosition();
    render({ loading: true });

    const canResolve = isYouTubeWatch() || findMainVideo() || detected.length > 0 || [...sniffed.values()].some((s) => s.stream);
    if (!canResolve) {
      render({ formats: null });
      return;
    }
    if (lastFormatsURL === location.href && lastFormats) {
      render({ formats: lastFormats });
      return;
    }

    const token = ++requestToken;
    native({ action: "formats", url: location.href, referer: location.href }).then((reply) => {
      if (token !== requestToken) return;
      if (reply.ok) {
        lastFormatsURL = location.href;
        lastFormats = reply;
        lastFormatsFailure = null;
      } else {
        lastFormatsFailure = reply;
      }
      render({ formats: reply });
    });
  }

  // Drag handle + close button, shown at the top of the panel.
  const panelHeader = el("div", {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    margin: "-4px 0 6px", cursor: "grab", userSelect: "none"
  });
  panelHeader.appendChild(el("span", { color: "#9aa0a6", fontSize: "11px", fontWeight: "600" }, "⠿ MacDM"));
  const panelClose = el("button", {
    border: "none", background: "transparent", color: "#9aa0a6", cursor: "pointer",
    font: `600 13px ${FONT}`, padding: "0 2px"
  }, "✕");
  panelClose.title = "Close";
  panelClose.addEventListener("click", (e) => { e.stopPropagation(); closePanel(); });
  panelHeader.appendChild(panelClose);
  makeDraggable(panelHeader, panelOffset);

  function sectionTitle(text) {
    return el("div", { fontWeight: "600", margin: "10px 0 6px", color: "#9aa0a6", fontSize: "11px", textTransform: "uppercase" }, text);
  }

  /** The blue Download button: shows "Sending…", then "Added ✓" or "Failed" (with the reason as a tooltip). */
  function downloadButton(onDownload) {
    const button = el("button", {
      border: "none", borderRadius: "4px", padding: "4px 10px", cursor: "pointer",
      background: "#1a73e8", color: "#fff", font: `600 12px ${FONT}`
    }, "Download");
    button.addEventListener("click", () => {
      button.textContent = "Sending…";
      button.disabled = true;
      onDownload().then((reply) => {
        button.textContent = reply.ok ? "Added ✓" : "Failed";
        button.title = reply.ok ? "" : (reply.error || "");
        if (!reply.ok) { button.disabled = false; button.style.background = "#d93025"; }
      });
    });
    return button;
  }

  function actionRow(label, detail, onDownload) {
    const row = el("div", { display: "flex", alignItems: "center", justifyContent: "space-between", padding: "6px 0", borderTop: "1px solid #3c4043" });
    const text = el("div", { flex: "1", minWidth: "0", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }, label);
    if (detail) text.appendChild(el("span", { color: "#9aa0a6", marginLeft: "8px" }, detail));
    row.appendChild(text);
    row.appendChild(downloadButton(onDownload));
    return row;
  }

  // ---- the "Choose quality" list: quality name | resolution | size | Download ----

  const QUALITY_COLUMNS = "minmax(78px, 1.2fr) 92px 62px auto";

  /** A plain name for a picture size. The shorter side decides, so a vertical video is named like a wide one. */
  function qualityName(width, height) {
    const side = width && height ? Math.min(width, height) : height;
    if (!side) return "";
    if (side >= 4320) return "8K";
    if (side >= 2160) return "4K";
    if (side >= 1440) return "2K";
    if (side >= 1080) return "Full HD";
    if (side >= 720) return "HD";
    if (side >= 480) return "SD";
    return "Low";
  }

  /** The four parts of one quality row, from what MacDM sent. Older MacDM versions send no pixel size. */
  function describeQuality(option) {
    if (option.audioOnly) return { name: "Audio only", resolution: "—" };
    const labelHeight = /^(\d+)p$/.exec(option.label || "");
    const height = option.height || (labelHeight ? parseInt(labelHeight[1], 10) : 0);
    const name = qualityName(option.width, height) || option.label;
    if (option.width && option.height) return { name, resolution: `${option.width} × ${option.height}` };
    return { name, resolution: labelHeight ? option.label : "—" };   // no pixel size known: the old "1080p" label
  }

  const GRID_ROW = { display: "grid", gridTemplateColumns: QUALITY_COLUMNS, columnGap: "8px", alignItems: "center" };

  function qualityHeading() {
    const cell = (text, align) => el("div", { textAlign: align || "left" }, text);
    const row = el("div", { ...GRID_ROW, padding: "0 0 4px", color: "#9aa0a6", fontSize: "11px", textTransform: "uppercase" });
    for (const node of [cell("Quality"), cell("Resolution"), cell("Size", "right"), cell("")]) row.appendChild(node);
    return row;
  }

  function qualityRow(option, onDownload) {
    const { name, resolution } = describeQuality(option);
    const row = el("div", { ...GRID_ROW, padding: "6px 0", borderTop: "1px solid #3c4043" });
    row.appendChild(el("div", { fontWeight: "600", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }, name));
    row.appendChild(el("div", { color: "#bdc1c6", whiteSpace: "nowrap" }, resolution));
    row.appendChild(el("div", { color: "#9aa0a6", textAlign: "right", whiteSpace: "nowrap" }, formatBytes(option.sizeBytes) || "—"));
    row.appendChild(downloadButton(onDownload));
    return row;
  }

  // Everything found on this page, newest first: from network traffic (any frame) and from this page's own requests.
  function allFinds() {
    const byUrl = new Map();
    for (const item of [...sniffed.values()].map((s) => ({ url: s.url, kind: s.stream ? "hls" : "file", size: 0, headers: {} }))) {
      byUrl.set(item.url, item);
    }
    for (const item of detected) byUrl.set(item.url, { headers: {}, size: 0, ...item });   // network finds carry headers and sizes
    return [...byUrl.values()].reverse();
  }

  // What each detected stream is (sharpness, length, rough size), read by MacDM from its playlist.
  const streamInfo = new Map();   // url -> reply, or "loading"

  function currentFormats() { return lastFormats || lastFormatsFailure; }

  function lookUpStream(item) {
    if (item.kind !== "hls" || streamInfo.has(item.url)) return;
    streamInfo.set(item.url, "loading");
    native({ action: "stream_info", url: item.url, headers: { Referer: location.href, ...(item.headers || {}) } })
      .then((reply) => {
        streamInfo.set(item.url, reply);
        if (panelOpen) render({ formats: currentFormats() });
      });
  }

  function streamDetail(item) {
    const info = streamInfo.get(item.url);
    const known = info && info !== "loading" && info.ok ? info : null;
    return [
      item.kind === "hls" ? "HLS stream" : item.kind === "dash" ? "DASH stream" : "",
      known && known.height ? `${known.height}p` : "",
      known && known.duration ? formatDuration(known.duration) : "",
      formatBytes(item.size) || (known && known.sizeBytes ? `~${formatBytes(known.sizeBytes)}` : "")
    ].filter(Boolean).join(" · ");
  }

  // A video link often ends in a hash with no ".mp4" (https://cdn.test/92af9fb0-82fb501e). Saving it under that
  // name gives a file nothing recognises, so such a file is named after the page, with the ending its
  // content type says.
  const TYPE_EXTENSIONS = {
    "video/mp4": "mp4", "video/x-m4v": "m4v", "video/webm": "webm", "video/x-matroska": "mkv",
    "video/quicktime": "mov", "video/ogg": "ogv", "video/mpeg": "mpg",
    "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac",
    "audio/ogg": "ogg", "audio/opus": "opus", "audio/flac": "flac", "audio/wav": "wav", "audio/x-wav": "wav"
  };
  const KNOWN_ENDING = /\.(mp4|m4v|webm|mkv|mov|avi|flv|ogv|mpg|mp3|m4a|aac|ogg|opus|flac|wav)$/i;

  function cleanTitle(text) {
    return String(text || "").replace(/[\\/:*?"<>|\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 150);
  }

  function suggestedName(item) {
    const fromUrl = displayName(item);
    if (item.kind !== "file" || KNOWN_ENDING.test(fromUrl)) return fromUrl;
    const type = String(item.contentType || "").split(";")[0].trim().toLowerCase();
    const ending = TYPE_EXTENSIONS[type] || (type.startsWith("video/") ? "mp4" : type.startsWith("audio/") ? "m4a" : "");
    if (!ending) return fromUrl;   // no way to tell what it is: leave it as the link names it
    return `${cleanTitle(document.title) || fromUrl}.${ending}`;
  }

  function displayName(item) {
    try {
      return decodeURIComponent(item.url.split("?")[0].split("/").pop() || item.url);
    } catch (_) {
      return item.url;
    }
  }

  // Streams (HLS/DASH) go through yt-dlp; plain files download directly. Both carry the browser's own
  // Referer, cookies and User-Agent so servers that check them accept MacDM.
  function downloadFind(item, name) {
    const headers = { Referer: location.href, ...(item.headers || {}) };
    return item.kind === "hls" || item.kind === "dash"
      ? native({ action: "download_media", url: item.url, title: document.title || name, selector: "b/bv*+ba", audioOnly: false, referer: location.href, headers })
      : native({ action: "download", url: item.url, suggestedFileName: name, forced: true, sourcePageURL: location.href, headers });
  }

  function render({ loading, formats }) {
    panel.textContent = "";
    panel.appendChild(panelHeader);

    if (loading) {
      panel.appendChild(el("div", { padding: "8px 0" }, "Fetching available qualities…"));
      return;
    }

    if (formats && formats.ok) {
      panel.appendChild(el("div", { fontWeight: "600", marginBottom: "2px", lineHeight: "1.3" }, formats.title));
      const duration = formatDuration(formats.duration);
      if (duration) panel.appendChild(el("div", { color: "#9aa0a6", fontSize: "12px" }, duration));
      if (!formats.ffmpeg) {
        panel.appendChild(el("div", { color: "#fdd663", fontSize: "12px", marginTop: "6px" },
          "ffmpeg not found: only qualities with built-in audio are listed. Install with: brew install ffmpeg"));
      }
      panel.appendChild(sectionTitle("Choose quality"));
      panel.appendChild(qualityHeading());
      for (const option of formats.options) {
        panel.appendChild(qualityRow(option, () => native({
          action: "download_media",
          url: location.href,
          title: formats.title,
          selector: option.selector,
          audioOnly: option.audioOnly,
          referer: location.href
        })));
      }
    }

    const direct = allFinds();
    if (formats && !formats.ok) {
      // The page address itself can't be read (an embedded player, for example). If the network showed
      // media, that is the way to download, so this is a note rather than a red error.
      panel.appendChild(direct.length > 0
        ? el("div", { color: "#9aa0a6", padding: "4px 0", lineHeight: "1.4", fontSize: "12px" }, "Quality choices aren't available for this page. Download what was detected below.")
        : el("div", { color: "#f28b82", padding: "4px 0", lineHeight: "1.4" }, formats.error || "Could not read this page."));
    }
    if (direct.length > 0) {
      panel.appendChild(sectionTitle("Detected media on this page"));
      for (const item of direct.slice(0, 8)) {
        const name = suggestedName(item);
        lookUpStream(item);
        const detail = streamDetail(item);
        panel.appendChild(actionRow(name, detail, () => downloadFind(item, name)));
      }
    }

    if (!formats && direct.length === 0) {
      panel.appendChild(el("div", { padding: "8px 0", color: "#9aa0a6" }, "No downloadable media found on this page yet. Play the video and try again."));
    }

    if (canGrab) panel.appendChild(grabButton());
  }

  // Sends every file link on the page, with the browser's login, to MacDM's Site Grabber.
  function grabButton() {
    const wrap = el("div", { borderTop: "1px solid #3c4043", marginTop: "10px", paddingTop: "8px" });
    const button = el("button", {
      border: "1px solid #5f6368", borderRadius: "4px", padding: "5px 10px", cursor: "pointer",
      background: "transparent", color: "#e8eaed", font: `600 12px ${FONT}`
    }, "Grab all files on this page…");
    button.addEventListener("click", () => {
      button.textContent = "Collecting…";
      button.disabled = true;
      chrome.runtime.sendMessage({ type: "grab-page" })
        .then((reply) => (reply || { ok: false, error: "No reply from MacDM." }))
        .catch((error) => ({ ok: false, error: String((error && error.message) || error) }))
        .then((reply) => {
          button.textContent = reply.ok ? "Opened in MacDM ✓" : "Failed";
          button.title = reply.ok ? "" : (reply.error || "");
          if (!reply.ok && reply.error) wrap.appendChild(el("div", { color: "#f28b82", fontSize: "12px", marginTop: "6px", lineHeight: "1.4" }, reply.error));
          if (!reply.ok) { button.disabled = false; button.style.borderColor = "#d93025"; }
        });
    });
    wrap.appendChild(button);
    return wrap;
  }

  // ---------- sniffing ----------

  function noteResource(url) {
    if (!url || url.startsWith("blob:") || url.startsWith("data:")) return;
    if (!MEDIA_RE.test(url)) return;
    let hostname;
    try { hostname = new URL(url).hostname; } catch (_) { return; }
    if (SKIP_HOSTS.test(hostname)) return;
    // YouTube is handled by yt-dlp; its own requests here are just UI sounds.
    if (/(^|\.)youtube\.com$/.test(location.hostname)) return;
    if (sniffed.has(url)) return;
    sniffed.set(url, { url, stream: STREAM_RE.test(url) });
    if (panelOpen) render({ formats: currentFormats() });
    updatePosition();
  }

  try {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) noteResource(entry.name);
    });
    observer.observe({ type: "resource", buffered: true });
  } catch (_) {
    // PerformanceObserver "resource" not supported: bar still works for <video> pages.
  }

  refreshDetected();
  every(refreshDetected, 3000);   // safety net in case a push message was missed

  // Clear stale sniffing results when a single-page app navigates.
  let lastHref = location.href;
  every(() => {
    if (location.href !== lastHref) {
      lastHref = location.href;
      sniffed.clear();
      detected = [];
      refreshDetected();
      lastFormatsURL = null;
      lastFormats = null;
      barDismissed = false;
      if (panelOpen) openPanel();
    }
  }, 1000);
})();
