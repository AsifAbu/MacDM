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
  let panelOpen = false;
  let requestToken = 0;
  let lastFormatsURL = null;
  let lastFormats = null;
  let barDismissed = false; // user removed the bar with its x button
  const barOffset = { x: 0, y: 0 };   // user drag offsets
  const panelOffset = { x: 0, y: 0 };

  // ---------- messaging ----------

  function native(payload) {
    return chrome.runtime
      .sendMessage({ type: "native", payload })
      .then((reply) => reply || { ok: false, error: "No reply from MacDM." })
      .catch((error) => ({ ok: false, error: String((error && error.message) || error) }));
  }

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
    position: "fixed", display: "none", width: "340px", maxHeight: "420px", overflowY: "auto",
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

  function findMainVideo() {
    let best = null;
    let bestArea = 0;
    for (const video of document.querySelectorAll("video")) {
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
    const hasMedia = video || sniffed.size > 0;
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
    const panelLeft = Math.max(Math.min(barRect.right - 340, window.innerWidth - 350), 10) + panelOffset.x;
    panel.style.top = `${clamp(panelTop, 0, window.innerHeight - 40)}px`;
    panel.style.left = `${clamp(panelLeft, 0, window.innerWidth - 100)}px`;
  }

  setInterval(updatePosition, 700);
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

    const canResolve = isYouTubeWatch() || findMainVideo() || [...sniffed.values()].some((s) => s.stream);
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

  function actionRow(label, detail, onDownload) {
    const row = el("div", { display: "flex", alignItems: "center", justifyContent: "space-between", padding: "6px 0", borderTop: "1px solid #3c4043" });
    const text = el("div", { flex: "1", minWidth: "0", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }, label);
    if (detail) text.appendChild(el("span", { color: "#9aa0a6", marginLeft: "8px" }, detail));
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
    row.appendChild(text);
    row.appendChild(button);
    return row;
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
      for (const option of formats.options) {
        panel.appendChild(actionRow(option.label, formatBytes(option.sizeBytes), () => native({
          action: "download_media",
          url: location.href,
          title: formats.title,
          selector: option.selector,
          audioOnly: option.audioOnly,
          referer: location.href
        })));
      }
    } else if (formats && !formats.ok) {
      panel.appendChild(el("div", { color: "#f28b82", padding: "4px 0", lineHeight: "1.4" }, formats.error || "Could not read this page."));
    }

    const direct = [...sniffed.values()];
    if (direct.length > 0) {
      panel.appendChild(sectionTitle("Detected media on this page"));
      for (const item of direct.slice(-6).reverse()) {
        const name = decodeURIComponent(item.url.split("?")[0].split("/").pop() || item.url);
        panel.appendChild(actionRow(name, item.stream ? "stream" : "", () => item.stream
          ? native({ action: "download_media", url: item.url, title: document.title || name, selector: "b/bv*+ba", audioOnly: false, referer: location.href })
          : native({ action: "download", url: item.url, suggestedFileName: name, forced: true, sourcePageURL: location.href })));
      }
    }

    if (!formats && direct.length === 0) {
      panel.appendChild(el("div", { padding: "8px 0", color: "#9aa0a6" }, "No downloadable media found on this page yet. Play the video and try again."));
    }
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
    if (panelOpen) render({ formats: lastFormats });
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

  // Clear stale sniffing results when a single-page app navigates.
  let lastHref = location.href;
  setInterval(() => {
    if (location.href !== lastHref) {
      lastHref = location.href;
      sniffed.clear();
      lastFormatsURL = null;
      lastFormats = null;
      barDismissed = false;
      if (panelOpen) openPanel();
    }
  }, 1000);
})();
