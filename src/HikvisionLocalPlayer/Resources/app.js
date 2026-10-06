const form = document.getElementById("connectionForm");
const hostInput = document.getElementById("host");
const usernameInput = document.getElementById("username");
const passwordInput = document.getElementById("password");
const rememberInput = document.getElementById("rememberPassword");
const channelInput = document.getElementById("channel");
const channelSection = document.getElementById("channelSection");
const channelHelp = document.getElementById("channelHelp");
const connectButton = document.getElementById("connectButton");
const disconnectButton = document.getElementById("disconnectButton");
const discoverButton = document.getElementById("discoverButton");
const togglePassword = document.getElementById("togglePassword");
const message = document.getElementById("message");
const engineStatus = document.getElementById("engineStatus");
const viewerCard = document.getElementById("viewerCard");
const viewerStage = document.getElementById("viewerStage");
const playerGrid = document.getElementById("playerGrid");
const emptyState = document.getElementById("emptyState");
const loadingState = document.getElementById("loadingState");
const streamLabel = document.getElementById("streamLabel");
const connectionDetail = document.getElementById("connectionDetail");
const fullscreenButton = document.getElementById("fullscreenButton");
const refreshPlayer = document.getElementById("refreshPlayer");
const workspace = document.getElementById("workspace");
const settingsPanel = document.getElementById("settingsPanel");
const collapseSidebarButton = document.getElementById("collapseSidebarButton");
const expandSidebarButton = document.getElementById("expandSidebarButton");

let lastPlayers = [];
let lastLayout = "single";
const sidebarStateKey = "hikSidebarCollapsed";

function selectedValue(name) {
  return form.querySelector(`input[name="${name}"]:checked`).value;
}

function setMessage(text, kind = "") {
  message.className = `message ${kind}`.trim();
  message.querySelector(".message-icon").textContent = kind === "success" ? "✓" : kind === "error" ? "!" : "i";
  message.lastElementChild.textContent = text;
}

function setBusy(busy) {
  connectButton.disabled = busy;
  discoverButton.disabled = busy;
  if (busy) {
    emptyState.hidden = true;
    loadingState.hidden = false;
    viewerCard.classList.remove("is-live");
  } else {
    loadingState.hidden = true;
  }
}

function updateLayoutUi() {
  const grid = selectedValue("layout") === "grid4";
  channelSection.hidden = grid;
  channelInput.required = !grid;
  connectButton.lastElementChild.textContent = grid ? "连接四画面" : "连接并播放";
}

function setSidebarCollapsed(collapsed, persist = true) {
  workspace.classList.toggle("sidebar-collapsed", collapsed);
  settingsPanel.setAttribute("aria-hidden", String(collapsed));
  settingsPanel.inert = collapsed;
  collapseSidebarButton.setAttribute("aria-expanded", String(!collapsed));
  expandSidebarButton.setAttribute("aria-expanded", String(!collapsed));
  expandSidebarButton.hidden = !collapsed;

  if (persist) {
    try { localStorage.setItem(sidebarStateKey, collapsed ? "1" : "0"); } catch {}
  }
}

function restoreSidebarState() {
  let collapsed = false;
  try { collapsed = localStorage.getItem(sidebarStateKey) === "1"; } catch {}
  setSidebarCollapsed(collapsed, false);
}

function formConfig() {
  return {
    Host: hostInput.value.trim(),
    Username: usernameInput.value.trim(),
    Password: passwordInput.value,
    Channel: Number(channelInput.value || 1),
    Stream: selectedValue("stream"),
    Layout: selectedValue("layout"),
    RememberPassword: rememberInput.checked
  };
}

async function request(path, options = {}, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(path, {
      ...options,
      signal: controller.signal,
      headers: { "Content-Type": "application/json", ...(options.headers || {}) }
    });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.message || `连接失败（${response.status}）`);
    return result;
  } catch (error) {
    if (error.name === "AbortError") throw new Error("连接超时，请检查录像机地址和网络。");
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

async function restoreSettings() {
  try {
    const result = await request("/api/settings", {}, 3000);
    const settings = result.settings || {};
    hostInput.value = settings.Host || "";
    usernameInput.value = settings.Username || "admin";
    passwordInput.value = settings.Password || "";
    rememberInput.checked = Boolean(settings.RememberPassword && settings.Password);
    const stream = settings.Stream === "main" ? "main" : "sub";
    const layout = settings.Layout === "grid4" ? "grid4" : "single";
    form.querySelector(`input[name="stream"][value="${stream}"]`).checked = true;
    form.querySelector(`input[name="layout"][value="${layout}"]`).checked = true;
    channelInput.innerHTML = `<option value="${settings.Channel || 1}">通道 ${settings.Channel || 1}</option>`;
    updateLayoutUi();
  } catch (error) {
    setMessage(error.message, "error");
  }
}

async function checkEngine() {
  try {
    await request("/api/health", {}, 2500);
    engineStatus.className = "engine-status ok";
    engineStatus.lastElementChild.textContent = "本机播放引擎正常";
  } catch {
    engineStatus.className = "engine-status bad";
    engineStatus.lastElementChild.textContent = "播放引擎不可用";
  }
}

function updateChannels(channels, selected) {
  channelInput.innerHTML = channels.map(item =>
    `<option value="${item.channel}">通道 ${item.channel}</option>`
  ).join("");
  if (channels.some(item => item.channel === selected)) channelInput.value = String(selected);
  channelHelp.textContent = `已读取 ${channels.length} 路通道（录像机内部编号：${channels.map(item => item.deviceId).join("、")}）`;
}

async function discoverChannels(showSuccess = true) {
  const config = formConfig();
  if (!config.Host || !config.Username || !config.Password) throw new Error("请先填写录像机地址、用户名和密码。");
  discoverButton.disabled = true;
  channelHelp.textContent = "正在读取录像机通道…";
  try {
    const result = await request("/api/discover", {
      method: "POST",
      body: JSON.stringify(config)
    });
    updateChannels(result.channels, config.Channel);
    if (showSuccess) setMessage(`已发现 ${result.channels.length} 路可用监控通道。`, "success");
    return result.channels;
  } finally {
    discoverButton.disabled = false;
  }
}

function clearPlayerGrid() {
  for (const frame of playerGrid.querySelectorAll("iframe")) frame.src = "about:blank";
  playerGrid.replaceChildren();
  playerGrid.className = "player-grid";
}

function renderPlayers(players, layout, refresh = false) {
  clearPlayerGrid();
  playerGrid.classList.toggle("grid4", layout === "grid4");

  for (const player of players) {
    const cell = document.createElement("div");
    cell.className = "player-cell";

    if (layout === "grid4") {
      const label = document.createElement("span");
      label.className = "cell-label";
      const streamName = player.stream === "main" ? "主码流" : "子码流";
      label.textContent = `通道 ${player.channel} · ${streamName}${player.fallbackUsed ? "（自动切换）" : ""}`;
      cell.appendChild(label);
    }

    const frame = document.createElement("iframe");
    frame.title = `通道 ${player.channel} 实时监控画面`;
    frame.allow = "autoplay; fullscreen";
    frame.referrerPolicy = "no-referrer";
    frame.src = `${player.playerUrl}&t=${Date.now()}${refresh ? `-${player.channel}` : ""}`;
    cell.appendChild(frame);
    playerGrid.appendChild(cell);
  }

  if (layout === "grid4") {
    while (playerGrid.children.length < 4) {
      const empty = document.createElement("div");
      empty.className = "player-cell empty-cell";
      empty.textContent = "未配置通道";
      playerGrid.appendChild(empty);
    }
  }
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  const config = formConfig();
  if (!config.Host || !config.Username || !config.Password) {
    setMessage("请填写完整的录像机连接信息。", "error");
    return;
  }

  setBusy(true);
  setMessage(config.Layout === "grid4" ? "正在并行测试最多 4 路实时码流…" : "正在读取通道并测试实时码流…");
  streamLabel.textContent = "正在连接";
  clearPlayerGrid();
  lastPlayers = [];

  try {
    const result = await request("/api/connect", {
      method: "POST",
      body: JSON.stringify(config)
    }, config.Layout === "grid4" ? 45000 : 30000);

    lastPlayers = result.players || [];
    lastLayout = result.layout || config.Layout;
    renderPlayers(lastPlayers, lastLayout);
    viewerCard.classList.add("is-live");
    emptyState.hidden = true;
    refreshPlayer.disabled = false;
    disconnectButton.disabled = false;

    const fallbackCount = lastPlayers.filter(player => player.fallbackUsed).length;
    if (lastLayout === "grid4") {
      streamLabel.textContent = `四画面 · ${lastPlayers.length} 路`;
      connectionDetail.textContent = `${config.Host} · 已连接 ${lastPlayers.length} 路实时监控`;
      let detail = `四画面已连接 ${lastPlayers.length} 路。`;
      if (result.failedCount) detail += ` ${result.failedCount} 路连接失败。`;
      if (fallbackCount) detail += ` ${fallbackCount} 路已从子码流自动切换到主码流。`;
      setMessage(detail, result.failedCount ? "" : "success");
    } else {
      const player = lastPlayers[0];
      const label = player.stream === "main" ? "主码流" : "子码流";
      streamLabel.textContent = `通道 ${player.channel} · ${label}`;
      connectionDetail.textContent = `${config.Host} · 设备通道 ${player.deviceChannelId} · ${label}`;
      setMessage(`通道 ${player.channel} 已连接，正在播放${label}${player.fallbackUsed ? "（子码流不可用，已自动切换）" : ""}。`, "success");
      if (player.fallbackUsed) form.querySelector('input[name="stream"][value="main"]').checked = true;
    }
  } catch (error) {
    viewerCard.classList.remove("is-live");
    emptyState.hidden = false;
    streamLabel.textContent = "连接失败";
    setMessage(error.message, "error");
  } finally {
    setBusy(false);
  }
});

discoverButton.addEventListener("click", async () => {
  try {
    await discoverChannels(true);
  } catch (error) {
    channelHelp.textContent = error.message || "读取失败，请检查设备连接信息";
    setMessage(error.message, "error");
  }
});

for (const input of form.querySelectorAll('input[name="layout"]')) {
  input.addEventListener("change", updateLayoutUi);
}

collapseSidebarButton.addEventListener("click", () => {
  setSidebarCollapsed(true);
  expandSidebarButton.focus();
});

expandSidebarButton.addEventListener("click", () => {
  setSidebarCollapsed(false);
  collapseSidebarButton.focus();
});

disconnectButton.addEventListener("click", async () => {
  try { await request("/api/disconnect", { method: "POST", body: "{}" }, 8000); } catch {}
  clearPlayerGrid();
  lastPlayers = [];
  viewerCard.classList.remove("is-live");
  emptyState.hidden = false;
  streamLabel.textContent = "已停止";
  connectionDetail.textContent = "本机低延迟播放 · 数据不会上传到互联网";
  refreshPlayer.disabled = true;
  disconnectButton.disabled = true;
  setMessage("实时预览已停止。");
});

refreshPlayer.addEventListener("click", () => {
  if (!lastPlayers.length) return;
  renderPlayers(lastPlayers, lastLayout, true);
  setMessage(lastLayout === "grid4" ? "正在重新加载全部实时画面…" : "正在重新加载实时画面…");
});

togglePassword.addEventListener("click", () => {
  const show = passwordInput.type === "password";
  passwordInput.type = show ? "text" : "password";
  togglePassword.textContent = show ? "隐藏" : "显示";
});

fullscreenButton.addEventListener("click", async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await viewerStage.requestFullscreen({ navigationUI: "hide" });
  } catch {
    setMessage("系统未允许进入全屏，请重试。", "error");
  }
});

document.addEventListener("fullscreenchange", () => {
  fullscreenButton.textContent = document.fullscreenElement ? "退出全屏" : "全屏播放";
});

window.addEventListener("DOMContentLoaded", async () => {
  restoreSidebarState();
  await restoreSettings();
  await checkEngine();
  setInterval(checkEngine, 10000);
});
