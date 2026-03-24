import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

const state = {
  items: [],
  isProcessing: false,
  isPaused: false,
  stopRequested: false,
  currentFileId: null,
  supportsHardStop: false,
  tokenVerified: false,
  liveMessageQueue: [],
  liveMessageTimer: null,
};

const els = {};
let scrollAnimationFrame = null;

function $(id) {
  return document.getElementById(id);
}

function cacheElements() {
  [
    "settings-fab",
    "compact-add-btn",
    "settings-overlay",
    "settings-drawer",
    "close-settings-btn",
    "pick-files-btn",
    "open-settings-inline-btn",
    "diarize-toggle",
    "diarize-options",
    "num-speakers",
    "hf-token",
    "verify-btn",
    "token-status",
    "drop-zone",
    "settings-hint",
    "live-window",
    "live-title",
    "queue-section",
    "queue-list",
    "clear-queue-btn",
    "start-btn",
    "pause-btn",
    "stop-btn",
    "action-status",
    "batch-note",
    "results-section",
    "results-list",
    "download-all-btn",
    "live-stream-layer",
    "live-stream",
  ].forEach((id) => {
    els[id] = $(id);
  });
}

async function backendCommand(command, args = {}) {
  return invoke("backend_command", { command, args });
}

function normalizeQueueState(snapshot) {
  if (!snapshot) {
    return {
      items: [],
      isProcessing: false,
      isPaused: false,
      stopRequested: false,
      currentFileId: null,
      supportsHardStop: false,
    };
  }

  return {
    items: snapshot.items || snapshot.queue || [],
    isProcessing: Boolean(snapshot.isProcessing ?? snapshot.running),
    isPaused: Boolean(snapshot.isPaused ?? snapshot.paused),
    stopRequested: Boolean(snapshot.stopRequested ?? snapshot.stop_requested),
    currentFileId: snapshot.currentFileId ?? snapshot.current_file_id ?? null,
    supportsHardStop: Boolean(snapshot.supportsHardStop ?? snapshot.supports_hard_stop),
  };
}

function mergeQueuedItems(queuedItems) {
  const incoming = Array.isArray(queuedItems) ? queuedItems : [];
  if (!incoming.length) return normalizeQueueState(null);

  const existing = new Map(state.items.map((item) => [item.fileId, item]));
  for (const item of incoming) {
    const fileId = item.fileId ?? item.file_id ?? item.id;
    if (!fileId) continue;
    existing.set(fileId, {
      ...item,
      fileId,
      status: item.status || "pending",
      progress: item.progress ?? 0,
      message: item.message || "",
    });
  }

  return {
    items: Array.from(existing.values()),
    isProcessing: state.isProcessing,
    isPaused: state.isPaused,
    stopRequested: state.stopRequested,
    currentFileId: state.currentFileId,
    supportsHardStop: state.supportsHardStop,
  };
}

function basename(path) {
  return String(path).split(/[/\\]/).pop() || String(path);
}

function optimisticQueuedState(paths) {
  return {
    items: paths.map((path, index) => ({
      id: `optimistic-${Date.now()}-${index}`,
      fileId: `optimistic-${Date.now()}-${index}`,
      filename: basename(path),
      size: 0,
      status: "pending",
      progress: 0,
      message: "已加入，等待同步...",
      result: null,
      error: null,
    })),
    isProcessing: state.isProcessing,
    isPaused: state.isPaused,
    stopRequested: state.stopRequested,
    currentFileId: state.currentFileId,
    supportsHardStop: state.supportsHardStop,
  };
}

async function withTimeout(promise, ms, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = window.setTimeout(() => reject(new Error(`${label} 超時`)), ms);
      }),
    ]);
  } finally {
    if (timer) window.clearTimeout(timer);
  }
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function escapeHtml(str) {
  return String(str)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function statusClass(status) {
  return {
    processing: "processing",
    done: "done",
    error: "error",
    stopped: "stopped",
  }[status] || "";
}

function statusLabel(item) {
  const labels = {
    pending: "等待中",
    processing: item.message || "轉譯中",
    done: "完成",
    error: item.error || "失敗",
    stopped: "已停止",
  };
  return labels[item.status] || item.status;
}

function setFadeVisibility(element, visible) {
  if (!element) return;
  if (visible) {
    element.classList.remove("hidden");
    requestAnimationFrame(() => {
      element.classList.remove("is-hidden");
    });
    return;
  }

  element.classList.add("is-hidden");
}

function setActionStatus(message = "", tone = "") {
  if (!els["action-status"]) return;
  const hasMessage = Boolean(String(message || "").trim());
  els["action-status"].textContent = hasMessage ? String(message) : "";
  els["action-status"].classList.toggle("hidden", !hasMessage);
  els["action-status"].classList.remove("success", "error");
  if (hasMessage && tone) {
    els["action-status"].classList.add(tone);
  }
}

function setDiarizeOptionsVisible(visible) {
  const section = els["diarize-options"];
  if (!section) return;
  section.classList.toggle("is-collapsed", !visible);
  section.setAttribute("aria-hidden", visible ? "false" : "true");
}

function renderQueue() {
  els["queue-section"].classList.toggle("hidden", state.items.length === 0);
  els["queue-list"].innerHTML = state.items.map((item, index) => {
    const showProgress = item.status === "processing";
    return `
      <div class="queue-item">
        <div class="queue-item-head">
          <div class="queue-order">${String(index + 1).padStart(2, "0")}</div>
          <div class="queue-meta">
            <p class="queue-name">${escapeHtml(item.filename)}</p>
            <div class="queue-size">${formatSize(item.size)}</div>
            <div class="queue-status">${escapeHtml(item.message || statusLabel(item))}</div>
            ${showProgress ? `<div class="progress-track"><div class="progress-bar" style="width:${Math.max(item.progress || 5, 5)}%"></div></div>` : ""}
          </div>
          <div class="status-pill ${statusClass(item.status)}">${escapeHtml(statusLabel(item))}</div>
        </div>
      </div>
    `;
  }).join("");
}

function renderResults() {
  const doneItems = state.items.filter((item) => ["done", "error", "stopped"].includes(item.status));
  els["results-section"].classList.toggle("hidden", doneItems.length === 0);
  els["download-all-btn"].classList.toggle(
    "hidden",
    state.items.filter((item) => item.status === "done").length < 2,
  );

  els["results-list"].innerHTML = doneItems.map((item) => {
    if (item.status !== "done" || !item.result) {
      return `
        <div class="result-card">
          <div class="result-card-header">
            <div>
              <p class="result-card-title">${escapeHtml(item.filename)}</p>
              <p class="result-card-meta">${escapeHtml(item.error || statusLabel(item))}</p>
            </div>
            <div class="status-pill ${statusClass(item.status)}">${escapeHtml(statusLabel(item))}</div>
          </div>
        </div>
      `;
    }

    const meta = [
      item.result.language,
      `${item.result.count} 段`,
      item.result.has_speakers ? "語者分離" : "",
    ].filter(Boolean).join(" · ");

    return `
      <div class="result-card">
        <div class="result-card-header">
          <div>
            <p class="result-card-title">${escapeHtml(item.filename)}</p>
            <p class="result-card-meta">${escapeHtml(meta)}</p>
          </div>
          <div class="status-pill done">完成</div>
        </div>
        <pre class="transcript-box">${escapeHtml(item.result.text)}</pre>
        <div class="result-actions">
          <button class="button secondary copy-btn" data-text="${encodeURIComponent(item.result.text)}">複製</button>
          <button class="button secondary save-btn" data-file-id="${item.fileId}" data-filename="${encodeURIComponent(item.result.suggestedFilename)}">下載</button>
        </div>
      </div>
    `;
  }).join("");

  els["results-list"].querySelectorAll(".copy-btn").forEach((button) => {
    button.addEventListener("click", async () => {
      const text = decodeURIComponent(button.dataset.text || "");
      await navigator.clipboard.writeText(text);
      const original = button.textContent;
      button.textContent = "已複製";
      setTimeout(() => {
        button.textContent = original;
      }, 1200);
    });
  });

  els["results-list"].querySelectorAll(".save-btn").forEach((button) => {
    button.addEventListener("click", async () => {
      const fileId = button.dataset.fileId;
      const suggestedFilename = decodeURIComponent(button.dataset.filename || "");
      try {
        const saved = await invoke("save_result", { fileId, suggestedFilename });
        if (saved) {
          setActionStatus(`已下載 ${suggestedFilename}`, "success");
        }
      } catch (error) {
        setActionStatus(`下載失敗: ${error?.message || error}`, "error");
        window.alert(`下載失敗: ${error?.message || error}`);
      }
    });
  });
}

function updateControls() {
  const startable = state.items.some((item) => !["done", "error", "stopped"].includes(item.status));
  els["start-btn"].disabled = state.isProcessing || !startable;
  els["start-btn"].textContent = state.isProcessing ? (state.stopRequested ? "停止中..." : (state.isPaused ? "暫停中..." : "轉譯中...")) : "開始轉譯";
  els["pause-btn"].classList.toggle("hidden", !state.isProcessing);
  els["stop-btn"].classList.toggle("hidden", !state.isProcessing);
  els["pause-btn"].textContent = state.isPaused ? "繼續" : "暫停";
  els["batch-note"].classList.toggle("hidden", !state.isProcessing);
  els["batch-note"].textContent = state.supportsHardStop
    ? "停止會直接中止目前任務，未開始的其餘檔案會保留。"
    : "MLX 模式目前不支援硬停止；停止會在目前檔案完成後生效。";

  const compactVisible = state.isProcessing || state.items.length > 0;
  els["drop-zone"].classList.toggle("is-collapsed", compactVisible);
  els["settings-hint"].classList.toggle("is-collapsed", state.isProcessing);
  setFadeVisibility(els["compact-add-btn"], compactVisible);
  setFadeVisibility(els["live-window"], state.isProcessing);
  els["live-stream-layer"].classList.toggle("hidden", !state.isProcessing);
  document.body.classList.toggle("is-processing", state.isProcessing);
}

function applyQueueState(snapshot) {
  const normalized = normalizeQueueState(snapshot);
  state.items = normalized.items;
  state.isProcessing = normalized.isProcessing;
  state.isPaused = normalized.isPaused;
  state.stopRequested = normalized.stopRequested;
  state.currentFileId = normalized.currentFileId;
  state.supportsHardStop = normalized.supportsHardStop;
  renderQueue();
  renderResults();
  updateControls();
}

function openSettings() {
  els["settings-drawer"].classList.add("open");
  els["settings-overlay"].classList.remove("hidden");
}

function closeSettings() {
  els["settings-drawer"].classList.remove("open");
  els["settings-overlay"].classList.add("hidden");
}

function enqueueLiveText(text) {
  String(text)
    .split("\n")
    .map((part) => part.trim())
    .filter(Boolean)
    .forEach((part) => state.liveMessageQueue.push(part));
  scheduleLiveDrain();
}

function scheduleLiveDrain() {
  if (state.liveMessageTimer || state.liveMessageQueue.length === 0) return;
  state.liveMessageTimer = window.setTimeout(() => {
    state.liveMessageTimer = null;
    const next = state.liveMessageQueue.shift();
    if (next) addFloatingLine(next);
    if (state.liveMessageQueue.length) scheduleLiveDrain();
  }, 300 + Math.random() * 320);
}

function addFloatingLine(text) {
  const line = document.createElement("div");
  line.className = "floating-line";
  line.textContent = text;
  line.style.left = `${6 + Math.random() * 60}%`;
  line.style.setProperty("--drift-x", `${(Math.random() - 0.5) * 90}px`);
  line.style.setProperty("--float-duration", `${4.6 + Math.random() * 2.4}s`);
  els["live-stream"].appendChild(line);
  while (els["live-stream"].children.length > 14) {
    els["live-stream"].removeChild(els["live-stream"].firstElementChild);
  }
  line.addEventListener("animationend", () => line.remove());
}

function clearLiveStream() {
  els["live-stream"].innerHTML = "";
  state.liveMessageQueue = [];
  if (state.liveMessageTimer) {
    window.clearTimeout(state.liveMessageTimer);
    state.liveMessageTimer = null;
  }
}

function applyScrollMotionStyles() {
  scrollAnimationFrame = null;
  const offset = window.scrollY || document.documentElement.scrollTop || 0;
  document.documentElement.style.setProperty("--scroll-offset", `${offset.toFixed(2)}px`);
}

function bindScrollMotion() {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (reducedMotion.matches) return;

  const onScroll = () => {
    if (!scrollAnimationFrame) {
      scrollAnimationFrame = window.requestAnimationFrame(() => applyScrollMotionStyles());
    }
  };

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
}

async function loadInfo() {
  try {
    const info = await backendCommand("get_info");
    state.supportsHardStop = Boolean(info.supports_hard_stop);
    applyQueueState(info.state);
  } catch {
    // Desktop UI no longer surfaces system details.
  }
}

async function pickFiles() {
  try {
    const paths = await invoke("pick_audio_files");
    if (!paths || paths.length === 0) return;
    setActionStatus(`已選取 ${paths.length} 個檔案，正在加入序列...`);
    applyQueueState(optimisticQueuedState(paths));
    const result = await withTimeout(
      backendCommand("enqueue_files", { paths }),
      8000,
      "加入檔案",
    );
    if (result.queue || result.state) {
      applyQueueState(result.queue ?? result.state);
      setActionStatus(`已加入 ${paths.length} 個檔案`, "success");
      return;
    }
    if (result.queued) {
      applyQueueState(mergeQueuedItems(result.queued));
      setActionStatus(`已加入 ${result.queued.length} 個檔案`, "success");
      return;
    }
    throw new Error("加入檔案後沒有收到可更新的序列資料");
  } catch (error) {
    console.error(error);
    setActionStatus(`加入音訊檔案失敗: ${error?.message || error}`, "error");
    window.alert(`加入音訊檔案失敗: ${error?.message || error}`);
  }
}

async function verifyToken() {
  const token = els["hf-token"].value.trim();
  els["verify-btn"].disabled = true;
  els["verify-btn"].textContent = "驗證中...";
  try {
    const result = await backendCommand("verify_token", { token });
    els["token-status"].className = `status-text ${result.ok ? "success" : "error"}`;
    els["token-status"].textContent = result.message;
    els["token-status"].classList.remove("hidden");
    if (result.ok) {
      localStorage.setItem("hf_token", token);
      state.tokenVerified = true;
    }
  } catch (error) {
    els["token-status"].className = "status-text error";
    els["token-status"].textContent = error;
    els["token-status"].classList.remove("hidden");
  } finally {
    els["verify-btn"].disabled = false;
    els["verify-btn"].textContent = "驗證 Token";
  }
}

async function startAll() {
  try {
    const diarize = els["diarize-toggle"].checked;
    const token = els["hf-token"].value.trim();
    if (diarize && !token) {
      openSettings();
      window.alert("請先在設定中填入 HuggingFace Token");
      return;
    }
    if (token) localStorage.setItem("hf_token", token);

    els["start-btn"].disabled = true;
    els["start-btn"].textContent = "啟動中...";
    setActionStatus("正在啟動轉譯...");

    const result = await withTimeout(
      backendCommand("start_transcription", {
        diarize,
        speakers: Number(els["num-speakers"].value || "0"),
        token,
        language: "zh",
      }),
      8000,
      "開始轉譯",
    );

    if (result.queue || result.state) {
      applyQueueState(result.queue ?? result.state);
    } else {
      updateControls();
    }

    if (!result.started) {
      setActionStatus("目前沒有可開始的待轉譯檔案，或轉譯已在進行中。", "error");
      window.alert("目前沒有可開始的待轉譯檔案，或轉譯已在進行中。");
      return;
    }
    setActionStatus("已開始轉譯", "success");
  } catch (error) {
    updateControls();
    console.error(error);
    setActionStatus(`開始轉譯失敗: ${error?.message || error}`, "error");
    window.alert(`開始轉譯失敗: ${error?.message || error}`);
  }
}

async function togglePause() {
  const nextPaused = !state.isPaused;
  await backendCommand("pause_queue", { paused: nextPaused });
  setActionStatus(nextPaused ? "已暫停佇列" : "已恢復佇列", "success");
}

async function stopCurrent() {
  const result = await backendCommand("stop_current");
  if (result?.message) setActionStatus(result.message, result?.stopping ? "success" : "error");
  if (result?.message) enqueueLiveText(result.message);
}

async function downloadAll() {
  const fileIds = state.items.filter((item) => item.status === "done").map((item) => item.fileId);
  if (fileIds.length === 0) return;
  try {
    const saved = await invoke("save_all_results", { fileIds });
    if (saved) {
      setActionStatus("已下載全部結果", "success");
    }
  } catch (error) {
    setActionStatus(`下載全部失敗: ${error?.message || error}`, "error");
    window.alert(`下載全部失敗: ${error?.message || error}`);
  }
}

function bindEvents() {
  els["settings-fab"].addEventListener("click", openSettings);
  els["open-settings-inline-btn"].addEventListener("click", openSettings);
  els["close-settings-btn"].addEventListener("click", closeSettings);
  els["settings-overlay"].addEventListener("click", closeSettings);
  els["pick-files-btn"].addEventListener("click", (event) => {
    event.stopPropagation();
    void pickFiles();
  });
  els["drop-zone"].addEventListener("click", (event) => {
    if (event.target.closest("button")) return;
    void pickFiles();
  });
  els["compact-add-btn"].addEventListener("click", pickFiles);
  els["verify-btn"].addEventListener("click", verifyToken);
  els["start-btn"].addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    void startAll();
  });
  els["pause-btn"].addEventListener("click", togglePause);
  els["stop-btn"].addEventListener("click", stopCurrent);
  els["download-all-btn"].addEventListener("click", downloadAll);
  els["clear-queue-btn"].addEventListener("click", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (state.isProcessing) {
      setActionStatus("轉譯進行中無法清除全部。", "error");
      window.alert("轉譯進行中無法清除全部。");
      return;
    }
    try {
      setActionStatus("正在清除序列...");
      const result = await withTimeout(
        backendCommand("clear_queue", {}),
        8000,
        "清除全部",
      );
      applyQueueState(result.queue ?? result.state);
      setActionStatus("已清除全部檔案", "success");
    } catch (error) {
      console.error(error);
      setActionStatus(`清除全部失敗: ${error?.message || error}`, "error");
      window.alert(`清除全部失敗: ${error?.message || error}`);
    }
  });
  els["diarize-toggle"].addEventListener("change", () => {
    setDiarizeOptionsVisible(els["diarize-toggle"].checked);
  });
}

async function bindBackendEvents() {
  await listen("backend://event", ({ payload }) => {
    const eventName = payload.event;
    const data = payload.data;

    if (eventName === "queue_updated") {
      applyQueueState(data);
      if (!state.items.length && !state.isProcessing) {
        setActionStatus("");
      }
      const current = state.items.find((item) => item.fileId === state.currentFileId);
      if (current && state.isProcessing) {
        els["live-title"].textContent = `正在聆聽 — ${current.filename}`;
      }
      if (!state.isProcessing) clearLiveStream();
      return;
    }

    if (eventName === "task_started") {
      clearLiveStream();
      els["live-title"].textContent = `正在聆聽 — ${data.filename}`;
      enqueueLiveText("等待轉譯內容...");
      setFadeVisibility(els["live-window"], true);
      return;
    }

    if (eventName === "task_progress") {
      enqueueLiveText(data.message || "");
      return;
    }

    if (eventName === "task_partial_text") {
      enqueueLiveText(data.text || "");
      return;
    }

    if (eventName === "task_completed") {
      const item = state.items.find((candidate) => candidate.fileId === data.fileId);
      els["live-title"].textContent = `轉譯完成 — ${item?.filename || ""}`;
      enqueueLiveText("這一份已完成。");
      return;
    }

    if (eventName === "queue_paused" || eventName === "queue_resumed") {
      enqueueLiveText(data.message || "");
      return;
    }

    if (eventName === "backend_ready" && data.info?.state) {
      applyQueueState(data.info.state);
      return;
    }

    if (eventName === "task_failed" || eventName === "task_stopped" || eventName === "backend_error") {
      enqueueLiveText(data.message || "發生錯誤");
    }
  });
}

async function init() {
  cacheElements();
  bindEvents();
  bindScrollMotion();
  await bindBackendEvents();
  const savedToken = localStorage.getItem("hf_token") || "";
  if (savedToken) els["hf-token"].value = savedToken;
  setDiarizeOptionsVisible(els["diarize-toggle"].checked);
  await backendCommand("subscribe_events", {});
  await loadInfo();
  updateControls();
}

init().catch((error) => {
  console.error(error);
  window.alert(`桌面版初始化失敗: ${error}`);
});
