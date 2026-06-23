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
    airportInput: $("airportInput"),
    freqType: $("freqType"),
    startBtn: $("startBtn"),
    stopBtn: $("stopBtn"),
    polBtn: $("polBtn"),
    ffmpegHint: $("ffmpegHint"),
    sessionDetail: $("sessionDetail"),
    transcript: $("transcript"),
    emptyState: $("emptyState"),
    sourceLabel: $("sourceLabel"),
    listenBtn: $("listenBtn"),
    listenLabel: $("listenLabel"),
    volume: $("volume"),
    player: $("player"),
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
    modelBadge: $("model-badge"),
    modelWarning: $("modelWarning"),
    modelWarningText: $("modelWarningText"),
    modelWarningOverride: $("modelWarningOverride"),
    settingsToggle: $("settingsToggle"),
    settingsModal: $("settingsModal"),
    settingsClose: $("settingsClose"),
    setActiveModel: $("setActiveModel"),
    setMeasuredSpeed: $("setMeasuredSpeed"),
    setModelWarning: $("setModelWarning"),
    setUseTurbo: $("setUseTurbo"),
    setUseSmall: $("setUseSmall"),
    setRebench: $("setRebench"),
    setModelNote: $("setModelNote"),
    setThreshold: $("setThreshold"),
    setApplyThreshold: $("setApplyThreshold"),
  };

  let currentRunId = null;
  let lastStatus = null;
  let listening = false;   // browser is playing the live audio relay
  let wantAudio = false;   // user asked to hear this session (auto-resume across runs)
  let sessionRunning = false;   // a transcription session is active (blocks model switch)
  let lastModelStatus = null;   // most recent /api/model payload
  let ctxTouched = false;  // user manually edited airport/frequency (stop auto-detect)

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
    // Optional correction layer: when present, show the corrected text as primary
    // with a badge; the raw original + exact edits live in a collapsible below.
    const hasCorrection = !!rec.corrected && rec.corrected !== rec.text;
    const text = document.createElement("div");
    text.className = "tx-text";
    text.textContent = hasCorrection ? rec.corrected : rec.text;
    if (hasCorrection) {
      const badge = document.createElement("span");
      badge.className = "tx-corrected-badge";
      badge.textContent = "corrected";
      badge.title = "Edited by the correction layer — expand below to see changes";
      text.append(" ", badge);
    }
    const lat = document.createElement("div");
    lat.className = "tx-latency";
    lat.textContent =
      `capture→text ${Math.round(rec.capture_to_text_ms)} ms · ` +
      `transcribe ${Math.round(rec.transcribe_ms)} ms · ` +
      `RTF ${Number(rec.real_time_factor).toFixed(2)}`;
    div.append(meta, text, lat);

    // Note every change the correction layer made: collapsible from->to list plus
    // the raw original. Shown by default (not System-gated) — changes matter.
    if (hasCorrection) {
      const edits = rec.corrections || [];
      const det = document.createElement("details");
      det.className = "tx-corrections";
      const sum = document.createElement("summary");
      sum.textContent = `${edits.length} change${edits.length === 1 ? "" : "s"}`;
      det.appendChild(sum);
      const body = document.createElement("div");
      body.className = "tx-corrections-body";
      edits.forEach((e) => {
        const row = document.createElement("div");
        row.className = "tx-edit";
        const from = document.createElement("span");
        from.className = "edit-from";
        from.textContent = e.from;
        const arrow = document.createElement("span");
        arrow.className = "edit-arrow";
        arrow.textContent = "→";
        const to = document.createElement("span");
        to.className = "edit-to";
        to.textContent = e.to;
        row.append(from, arrow, to);
        const bits = [e.reason, e.confidence != null ? e.confidence : null, e.backend].filter(
          (b) => b != null && b !== ""
        );
        if (bits.length) {
          const m = document.createElement("span");
          m.className = "edit-meta";
          m.textContent = bits.join(" · ");
          row.append(m);
        }
        body.appendChild(row);
      });
      const raw = document.createElement("div");
      raw.className = "tx-raw";
      raw.textContent = `raw: ${rec.text}`;
      body.appendChild(raw);
      det.appendChild(body);
      div.append(det);
    }

    // The exact prompt injected for this transmission. A diagnostic, so it rides
    // with the System pane toggle (like latency) to keep the default view clean.
    if (rec.prompt) {
      const det = document.createElement("details");
      det.className = "tx-prompt";
      const sum = document.createElement("summary");
      sum.textContent = "injected prompt";
      const pre = document.createElement("pre");
      pre.className = "tx-prompt-text";
      pre.textContent = rec.prompt;
      det.append(sum, pre);
      div.append(det);
    }

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

    // New run -> clear the board, and (re)attach audio if the user wants to hear it.
    if (s.run_id != null && s.run_id !== currentRunId) {
      currentRunId = s.run_id;
      clearTranscript();
      if (wantAudio) startListening();
    }

    const map = STREAM_STATE[s.status] || ["idle", s.status];
    setPill(el.pillStream, map[0], map[1]);

    const running = ["starting", "connecting", "live", "stopping"].includes(s.status);
    el.startBtn.disabled = running;
    el.stopBtn.disabled = !running;
    el.listenBtn.disabled = !running;
    if (!running && listening) stopListening();
    if (running !== sessionRunning) {
      sessionRunning = running;
      refreshOverrideButtons();  // model switching is blocked while a session runs
    }

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
    html += `<div class="pol-meta">model ${escapeHtml(modelLabel(p.active_model))} · device ${escapeHtml(p.device || "—")} · ${
      p.realtime_speed != null ? p.realtime_speed.toFixed(2) + "x real-time" : "—"
    } · mean WER ${
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

  // ---------- model selection + settings ----------
  let modelPollTimer = null;
  const MODEL_LABEL = { turbo: "large · turbo", small: "small · fast", custom: "custom" };

  function modelLabel(name) {
    return name ? MODEL_LABEL[name] || name : "—";
  }

  // Override/re-benchmark buttons depend on BOTH the model state and whether a
  // session is running (the model can't be hot-swapped mid-session, so the server
  // returns 409). Compute their enabled state + the explanatory note in one place.
  function refreshOverrideButtons() {
    const m = lastModelStatus || {};
    const busy = !!m.selecting;
    const active = m.active_model;
    const avail = m.available || {};
    const block = busy || sessionRunning;
    el.setUseTurbo.disabled = block || active === "turbo" || avail.turbo === false;
    el.setUseSmall.disabled = block || active === "small" || avail.small === false;
    el.setRebench.disabled = block;
    if (el.modelWarningOverride) el.modelWarningOverride.disabled = sessionRunning;
    el.setModelNote.textContent = sessionRunning
      ? "Stop the running session to switch models — the model is in use while transcribing."
      : busy
      ? "Benchmarking the device on the larger model…"
      : m.auto_downgraded
      ? "Auto-selected the smaller model — this device is below the speed threshold."
      : `Using the ${m.adaptive ? "benchmark-selected" : "configured"} model.`;
  }

  function applyModelStatus(m) {
    if (!m) return;
    lastModelStatus = m;
    const active = m.active_model;
    const busy = !!m.selecting;

    el.modelBadge.innerHTML = busy
      ? "model&nbsp;·&nbsp;benchmarking…"
      : `model&nbsp;·&nbsp;${escapeHtml(modelLabel(active))}`;
    el.modelBadge.dataset.model = active || "";
    el.modelBadge.classList.toggle("benchmarking", busy);

    if (m.warning) {
      el.modelWarningText.textContent = m.warning;
      el.modelWarning.hidden = false;
    } else {
      el.modelWarning.hidden = true;
    }

    el.setActiveModel.textContent = busy ? "benchmarking…" : modelLabel(active);
    el.setActiveModel.dataset.model = active || "";
    el.setMeasuredSpeed.textContent =
      m.measured_speed != null ? `${m.measured_speed.toFixed(2)}x real-time` : "—";
    if (m.warning) {
      el.setModelWarning.textContent = m.warning;
      el.setModelWarning.hidden = false;
    } else {
      el.setModelWarning.hidden = true;
    }
    if (document.activeElement !== el.setThreshold && m.min_realtime_speed != null) {
      el.setThreshold.value = m.min_realtime_speed;
    }
    refreshOverrideButtons();

    if (el.sysModel) el.sysModel.textContent = busy ? "benchmarking…" : modelLabel(active);

    if (busy) {
      if (!modelPollTimer) modelPollTimer = setTimeout(fetchModelStatus, 1500);
    } else if (modelPollTimer) {
      clearTimeout(modelPollTimer);
      modelPollTimer = null;
    }
  }

  async function fetchModelStatus() {
    modelPollTimer = null;
    try {
      applyModelStatus(await api("/api/model"));
    } catch (_) {
      modelPollTimer = setTimeout(fetchModelStatus, 3000);
    }
  }

  async function overrideModel(name) {
    el.modelBadge.classList.add("benchmarking");
    try {
      const m = await api("/api/model/override", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: name }),
      });
      applyModelStatus(m);
      runProofOfLife(true);
    } catch (e) {
      flash(el.sessionDetail, e.message);
      fetchModelStatus();
    }
  }

  async function reBenchmark() {
    el.modelBadge.innerHTML = "model&nbsp;·&nbsp;benchmarking…";
    el.modelBadge.classList.add("benchmarking");
    el.setModelNote.textContent = "Benchmarking…";
    try {
      applyModelStatus(await api("/api/model/auto-select", { method: "POST" }));
      runProofOfLife(true);
    } catch (e) {
      flash(el.sessionDetail, e.message);
      fetchModelStatus();
    }
  }

  async function saveThreshold() {
    const v = parseFloat(el.setThreshold.value);
    if (isNaN(v) || v < 0) {
      flash(el.sessionDetail, "Enter a valid speed threshold.");
      return;
    }
    try {
      await api("/api/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ min_realtime_speed: v }),
      });
      await reBenchmark();
    } catch (e) {
      flash(el.sessionDetail, e.message);
    }
  }

  function openSettings() {
    el.settingsModal.hidden = false;
    fetchModelStatus();
  }
  function closeSettings() {
    el.settingsModal.hidden = true;
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
    el.airportInput.disabled = !isCustom;
    el.freqType.disabled = !isCustom;
    if (isCustom) el.urlInput.focus();
  }

  // Best-effort airport + frequency-type detection from a LiveATC link/mount,
  // e.g. ".../hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c" -> KDFW, approach.
  function detectContext(url) {
    let icao = "", freq = "";
    url = url || "";
    const icaoQ = url.match(/[?&]icao=([a-z]{3,4})\b/i);
    let mount = "";
    const mountQ = url.match(/[?&]mount=([a-z0-9_]+)/i);
    if (mountQ) mount = mountQ[1];
    else mount = (url.split("?")[0].split("/").filter(Boolean).pop() || "");
    if (icaoQ) icao = icaoQ[1].toUpperCase();
    else {
      const lead = (mount.match(/^([a-z]{3,4})/i) || [])[1];
      if (lead) icao = lead.toUpperCase();
    }
    const m = mount.toLowerCase();
    if (/(^|_)(app|appr|fin|final)/.test(m)) freq = "approach";
    else if (/(^|_)dep/.test(m)) freq = "departure";
    else if (/(^|_)(twr|tower)/.test(m)) freq = "tower";
    else if (/(^|_)(gnd|ground)/.test(m)) freq = "ground";
    else if (/(^|_)(del|clnc|clr|cd)/.test(m)) freq = "clearance";
    else if (/(^|_)(ctr|cent)/.test(m)) freq = "center";
    else if (/(^|_)(ctaf|unicom)/.test(m)) freq = "ctaf";
    return { icao, freq };
  }

  function autofillContext() {
    if (ctxTouched) return;  // respect manual edits
    const { icao, freq } = detectContext(el.urlInput.value.trim());
    el.airportInput.value = icao;
    el.freqType.value = freq;
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
      const ap = el.airportInput.value.trim();
      if (ap) body.airport = ap;
      const ft = el.freqType.value;
      if (ft) body.frequency_type = ft;
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
      // Auto-attach audio for this session (applySession starts it on the new run).
      // This runs in the Start click's gesture, so browsers allow playback.
      wantAudio = true;
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

  // ---------- live audio relay ----------
  function setListenUI(on) {
    listening = on;
    if (!el.listenBtn) return;
    el.listenLabel.textContent = on ? "Listening" : "Listen";
    el.listenBtn.classList.toggle("btn-primary", on);
    el.listenBtn.classList.toggle("btn-ghost", !on);
  }

  function startListening() {
    if (!el.player) return;
    // Cache-bust + tag the run so we always attach to the current stream.
    el.player.src = `/api/session/audio?run=${currentRunId || 0}&t=${Date.now()}`;
    el.player.volume = parseFloat(el.volume.value || "0.9");
    setListenUI(true);
    const p = el.player.play();
    if (p && p.catch) {
      p.catch(() => {
        // Autoplay blocked (e.g. Safari without a direct gesture) or not ready yet.
        stopListening();
        flash(el.sessionDetail, "Press Listen to enable audio.");
      });
    }
  }

  function stopListening() {
    if (!el.player) return;
    try { el.player.pause(); } catch (_) {}
    el.player.removeAttribute("src");
    try { el.player.load(); } catch (_) {}  // drop the server connection
    setListenUI(false);
  }

  function toggleListen() {
    if (listening) {
      wantAudio = false;
      stopListening();
    } else {
      wantAudio = true;
      startListening();
    }
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
      // Refresh model status so the badge reflects the host's current choice
      // even if it changed while we were disconnected (e.g. a server restart).
      fetchModelStatus();
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
    el.listenBtn.addEventListener("click", toggleListen);
    el.volume.addEventListener("input", () => {
      if (el.player) el.player.volume = parseFloat(el.volume.value);
    });
    el.player.addEventListener("ended", () => setListenUI(false));
    el.player.addEventListener("error", () => { if (listening) stopListening(); });
    el.polBtn.addEventListener("click", () => runProofOfLife(true));
    el.clearBtn.addEventListener("click", clearTranscript);
    el.urlInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !el.startBtn.disabled) startSession();
    });
    // Auto-detect airport + frequency from the pasted link (until the user edits them).
    el.urlInput.addEventListener("input", autofillContext);
    el.airportInput.addEventListener("input", () => { ctxTouched = true; });
    el.freqType.addEventListener("change", () => { ctxTouched = true; });

    // model + settings
    el.settingsToggle.addEventListener("click", openSettings);
    el.settingsClose.addEventListener("click", closeSettings);
    el.settingsModal.addEventListener("click", (e) => {
      if (e.target === el.settingsModal) closeSettings();
    });
    el.setUseTurbo.addEventListener("click", () => overrideModel("turbo"));
    el.setUseSmall.addEventListener("click", () => overrideModel("small"));
    el.setRebench.addEventListener("click", reBenchmark);
    el.setApplyThreshold.addEventListener("click", saveThreshold);
    el.modelWarningOverride.addEventListener("click", () => overrideModel("turbo"));

    setPill(el.pillHandshake, "pending", "Handshake");
    loadFeeds();
    connectWS();
    fetchModelStatus();
    // Kick off the proof-of-life handshake automatically (loads the model once).
    runProofOfLife(false);
  }

  document.addEventListener("DOMContentLoaded", init);
})();
