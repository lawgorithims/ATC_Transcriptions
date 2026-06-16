/* ATC_Transcribe browser console — talks to the host running the model. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const el = {
    pillHandshake: $("pill-handshake"),
    pillPol: $("pill-pol"),
    pillStream: $("pill-stream"),
    deviceBadge: $("device-badge"),
    sourceSelect: $("sourceSelect"),
    urlInput: $("urlInput"),
    startBtn: $("startBtn"),
    stopBtn: $("stopBtn"),
    polBtn: $("polBtn"),
    ffmpegHint: $("ffmpegHint"),
    sessionDetail: $("sessionDetail"),
    transcript: $("transcript"),
    emptyState: $("emptyState"),
    sourceLabel: $("sourceLabel"),
    clearBtn: $("clearBtn"),
    statCount: $("statCount"),
    statCapture: $("statCapture"),
    statTranscribe: $("statTranscribe"),
    statRtf: $("statRtf"),
    statUptime: $("statUptime"),
    polBody: $("polBody"),
    sysDevice: $("sysDevice"),
    sysModel: $("sysModel"),
    sysFfmpeg: $("sysFfmpeg"),
    sysPlatform: $("sysPlatform"),
    connState: $("connState"),
    systemToggle: $("systemToggle"),
  };

  let currentRunId = null;
  let lastStatus = null;

  // ---------- appearance: theme + system pane ----------
  const THEME_KEY = "atc-theme";
  const SYSTEM_KEY = "atc-show-system";
  const THEME_COLORS = { cockpit: "#0b1117", day: "#f4f7fa", night: "#05080b" };

  function applyTheme(theme) {
    if (!THEME_COLORS[theme]) theme = "cockpit";
    document.documentElement.dataset.theme = theme;
    document.querySelectorAll("[data-theme-btn]").forEach((b) => {
      b.setAttribute("aria-pressed", String(b.dataset.themeBtn === theme));
    });
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", THEME_COLORS[theme]);
    try { localStorage.setItem(THEME_KEY, theme); } catch (_) {}
  }

  function applySystemPane(show) {
    document.body.classList.toggle("show-system", show);
    if (el.systemToggle) el.systemToggle.setAttribute("aria-expanded", String(show));
    try { localStorage.setItem(SYSTEM_KEY, show ? "1" : "0"); } catch (_) {}
  }

  function initAppearance() {
    let theme = "cockpit";
    let showSystem = false;
    try {
      theme = localStorage.getItem(THEME_KEY) || "cockpit";
      showSystem = localStorage.getItem(SYSTEM_KEY) === "1";
    } catch (_) {}
    applyTheme(theme);
    applySystemPane(showSystem);

    document.querySelectorAll("[data-theme-btn]").forEach((b) => {
      b.addEventListener("click", () => applyTheme(b.dataset.themeBtn));
    });
    if (el.systemToggle) {
      el.systemToggle.addEventListener("click", () =>
        applySystemPane(!document.body.classList.contains("show-system"))
      );
    }
  }

  // ---------- helpers ----------
  function setPill(pill, state, label) {
    pill.dataset.state = state;
    if (label) pill.querySelector(".pill-label").textContent = label;
  }

  function fmtMs(v) {
    if (v == null) return "—";
    return Math.round(v) + " ms";
  }

  function fmtUptime(s) {
    if (s == null) return "—";
    s = Math.round(s);
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return m > 0 ? `${m}m ${sec}s` : `${sec}s`;
  }

  async function api(path, opts) {
    const res = await fetch(path, opts);
    let body = null;
    try { body = await res.json(); } catch (_) {}
    if (!res.ok) {
      const msg = (body && body.error) || `HTTP ${res.status}`;
      throw new Error(msg);
    }
    return body;
  }

  // ---------- transcript rendering ----------
  function clearTranscript() {
    el.transcript.querySelectorAll(".tx").forEach((n) => n.remove());
    el.emptyState.style.display = "";
  }

  function appendRecord(rec) {
    el.emptyState.style.display = "none";
    const nearBottom =
      el.transcript.scrollHeight - el.transcript.scrollTop - el.transcript.clientHeight < 80;

    const prevLatest = el.transcript.querySelector(".tx.tx-latest");
    if (prevLatest) prevLatest.classList.remove("tx-latest");

    const div = document.createElement("div");
    div.className = "tx tx-latest";
    const meta = document.createElement("div");
    meta.className = "tx-meta";
    meta.innerHTML =
      `<span class="tx-time">${rec.timestamp || ""}</span>` +
      `<span class="tx-stream">stream ${Number(rec.stream_start_s).toFixed(1)}s</span>`;
    const text = document.createElement("div");
    text.className = "tx-text";
    text.textContent = rec.text;
    const lat = document.createElement("div");
    lat.className = "tx-latency";
    lat.textContent =
      `capture→text ${Math.round(rec.capture_to_text_ms)} ms · ` +
      `transcribe ${Math.round(rec.transcribe_ms)} ms · ` +
      `RTF ${Number(rec.real_time_factor).toFixed(2)}`;
    div.append(meta, text, lat);
    el.transcript.appendChild(div);

    if (nearBottom) el.transcript.scrollTop = el.transcript.scrollHeight;
  }

  // ---------- stream pill / status ----------
  const STREAM_STATE = {
    idle: ["idle", "Stream idle"],
    starting: ["pending", "Starting…"],
    connecting: ["pending", "Connecting…"],
    live: ["ok", "Stream live"],
    stopping: ["pending", "Stopping…"],
    stopped: ["idle", "Stopped"],
    error: ["error", "Stream error"],
  };

  function applySession(s) {
    if (!s) return;

    // New run -> clear the board.
    if (s.run_id != null && s.run_id !== currentRunId) {
      currentRunId = s.run_id;
      clearTranscript();
    }

    const map = STREAM_STATE[s.status] || ["idle", s.status];
    setPill(el.pillStream, map[0], map[1]);

    const running = ["starting", "connecting", "live", "stopping"].includes(s.status);
    el.startBtn.disabled = running;
    el.stopBtn.disabled = !running;

    el.sourceLabel.textContent = s.source_label || "No stream running";
    el.sessionDetail.textContent = s.detail || "";
    if (s.status === "error" && s.error) {
      el.sessionDetail.textContent = s.error;
      el.sessionDetail.classList.add("warn");
    } else {
      el.sessionDetail.classList.remove("warn");
    }

    if (Array.isArray(s.records)) s.records.forEach(appendRecord);

    const st = s.stats || {};
    el.statCount.textContent = st.count || 0;
    el.statCapture.textContent = st.capture_to_text_ms ? fmtMs(st.capture_to_text_ms.p50) : "—";
    el.statTranscribe.textContent = st.transcribe_ms ? fmtMs(st.transcribe_ms.p50) : "—";
    el.statRtf.textContent = st.real_time_factor ? Number(st.real_time_factor.mean).toFixed(2) : "—";
    el.statUptime.textContent = fmtUptime(s.uptime_s);

    lastStatus = s.status;
  }

  // ---------- health / system ----------
  function applyHealth(h) {
    if (!h) return;
    const dev = h.resolved_device || h.device_request || "—";
    el.deviceBadge.innerHTML = `device&nbsp;·&nbsp;${dev}`;
    el.sysDevice.textContent = dev + (h.model_loaded ? " (loaded)" : "");
    el.sysModel.textContent = h.model_available ? "available" : "MISSING";
    el.sysModel.style.color = h.model_available ? "" : "var(--state-critical)";
    el.sysFfmpeg.textContent = h.ffmpeg_available ? "available" : "not installed";
    el.sysFfmpeg.style.color = h.ffmpeg_available ? "" : "var(--state-caution)";
    el.sysPlatform.textContent = h.machine || h.platform || "—";
    el.sysPlatform.title = h.platform || "";

    if (!h.ffmpeg_available) {
      el.ffmpegHint.textContent = "⚠ ffmpeg not installed on host — live streams need it (replay demo still works).";
      el.ffmpegHint.classList.add("warn");
    } else {
      el.ffmpegHint.textContent = "";
      el.ffmpegHint.classList.remove("warn");
    }
  }

  // ---------- proof of life ----------
  function renderPol(p) {
    if (!p) return;
    if (p.error) {
      setPill(el.pillPol, "error", "Proof of life");
      el.polBody.innerHTML = `<div class="pol-verdict pol-fail"><span class="dot"></span>FAILED</div>
        <p class="muted">${escapeHtml(p.error)}</p>`;
      return;
    }
    setPill(el.pillPol, p.passed ? "ok" : "warn", "Proof of life");
    const verdictClass = p.passed ? "pol-pass" : "pol-fail";
    const verdictText = p.passed ? "PASS — transcriber alive" : "DEGRADED — check output";
    let html = `<div class="pol-verdict ${verdictClass}"><span class="dot"></span>${verdictText}</div>`;
    html += `<div class="pol-meta">device ${escapeHtml(p.device || "—")} · mean WER ${
      p.mean_wer != null ? (p.mean_wer * 100).toFixed(1) + "%" : "—"
    }${p.load_seconds != null ? " · load " + p.load_seconds + "s" : ""}</div>`;
    (p.snippets || []).forEach((s) => {
      if (!s.hypothesis && !s.reference) return;
      html += `<div class="pol-snip"><div class="ref">ref: ${escapeHtml(s.reference || "")}</div>
        <div class="hyp">hyp: ${escapeHtml(s.hypothesis || "<empty>")}</div></div>`;
    });
    html += `<div class="pol-meta">checked ${escapeHtml(p.checked_at || "")}</div>`;
    el.polBody.innerHTML = html;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }

  async function runProofOfLife(force) {
    setPill(el.pillPol, "pending", "Proof of life");
    el.polBtn.disabled = true;
    el.polBody.innerHTML = `<p class="muted">Running handshake (loading model on first run, this can take a while)…</p>`;
    try {
      const p = await api(`/api/proof-of-life?force=${force ? "true" : "false"}`, { method: "POST" });
      renderPol(p);
    } catch (e) {
      setPill(el.pillPol, "error", "Proof of life");
      el.polBody.innerHTML = `<p class="muted">${escapeHtml(e.message)}</p>`;
    } finally {
      el.polBtn.disabled = false;
    }
  }

  // ---------- feeds ----------
  async function loadFeeds() {
    let data;
    try {
      data = await api("/api/feeds");
    } catch (_) {
      return;
    }
    const sel = el.sourceSelect;
    sel.innerHTML = "";

    const custom = new Option("Custom stream URL", "custom");
    sel.add(custom);

    if (data.demo_available) {
      sel.add(new Option(data.demo_label || "Replay demo", "demo"));
    }

    if (data.feeds && data.feeds.length) {
      const group = document.createElement("optgroup");
      group.label = "Preset feeds";
      data.feeds.forEach((f, i) => {
        const labelBits = [f.label];
        if (f.frequency_mhz) labelBits.push(f.frequency_mhz + " MHz");
        const opt = new Option(labelBits.join(" · "), "feed:" + i);
        opt.dataset.feedConfig = f.feed_config;
        opt.dataset.feedKey = f.feed_key;
        opt.dataset.label = f.airport + " — " + f.label;
        group.appendChild(opt);
      });
      sel.add(group);
    }
    syncSourceFields();
  }

  function syncSourceFields() {
    const isCustom = el.sourceSelect.value === "custom";
    el.urlInput.disabled = !isCustom;
    if (isCustom) el.urlInput.focus();
  }

  // ---------- start / stop ----------
  async function startSession() {
    const val = el.sourceSelect.value;
    const body = {};
    if (val === "demo") {
      body.demo = true;
    } else if (val === "custom") {
      const url = el.urlInput.value.trim();
      if (!url) {
        el.urlInput.focus();
        flash(el.sessionDetail, "Paste a LiveATC link or stream URL first.");
        return;
      }
      body.stream_url = url;
    } else if (val.startsWith("feed:")) {
      const opt = el.sourceSelect.selectedOptions[0];
      body.feed_config = opt.dataset.feedConfig;
      body.feed_key = opt.dataset.feedKey;
      body.source_label = opt.dataset.label;
    }
    el.startBtn.disabled = true;
    try {
      const snap = await api("/api/session/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      applySession(snap);
    } catch (e) {
      flash(el.sessionDetail, e.message);
      el.startBtn.disabled = false;
    }
  }

  async function stopSession() {
    el.stopBtn.disabled = true;
    try {
      const snap = await api("/api/session/stop", { method: "POST" });
      applySession(snap);
    } catch (e) {
      flash(el.sessionDetail, e.message);
    }
  }

  function flash(node, msg) {
    node.textContent = msg;
    node.classList.add("warn");
    setTimeout(() => node.classList.remove("warn"), 4000);
  }

  // ---------- websocket ----------
  let ws = null;
  let reconnectTimer = null;

  function connectWS() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/ws`);

    ws.onopen = () => {
      setPill(el.pillHandshake, "ok", "Handshake");
      el.connState.textContent = "connected";
    };
    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (_) { return; }
      if (msg.type === "snapshot") {
        applyHealth(msg.health);
        applySession(msg.session);
      } else if (msg.type === "delta") {
        applySession(msg.session);
      }
    };
    ws.onclose = () => {
      setPill(el.pillHandshake, "error", "Handshake");
      el.connState.textContent = "disconnected — retrying…";
      if (!reconnectTimer) {
        reconnectTimer = setTimeout(() => {
          reconnectTimer = null;
          connectWS();
        }, 2000);
      }
    };
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }

  // ---------- boot ----------
  function init() {
    initAppearance();
    el.sourceSelect.addEventListener("change", syncSourceFields);
    el.startBtn.addEventListener("click", startSession);
    el.stopBtn.addEventListener("click", stopSession);
    el.polBtn.addEventListener("click", () => runProofOfLife(true));
    el.clearBtn.addEventListener("click", clearTranscript);
    el.urlInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !el.startBtn.disabled) startSession();
    });

    setPill(el.pillHandshake, "pending", "Handshake");
    loadFeeds();
    connectWS();
    // Kick off the proof-of-life handshake automatically (loads the model once).
    runProofOfLife(false);
  }

  document.addEventListener("DOMContentLoaded", init);
})();
