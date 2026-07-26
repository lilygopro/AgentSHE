const KEY = "agentshe_admin_key";

const $ = (sel) => document.querySelector(sel);
const gate = $("#gate");
const appEl = $("#app");
const agentList = $("#agent-list");
const stageEmpty = $("#stage-empty");
const stageAgent = $("#stage-agent");
const termOut = $("#term-out");

let sessions = [];
let currentId = null;
let pollTimer = null;

function getKey() {
  return sessionStorage.getItem(KEY) || "";
}

function setKey(k) {
  sessionStorage.setItem(KEY, k);
}

function clearKey() {
  sessionStorage.removeItem(KEY);
}

async function api(path, opts = {}) {
  const headers = Object.assign({}, opts.headers || {});
  const key = getKey();
  if (key) headers["X-Admin-Key"] = key;
  if (opts.body && !headers["Content-Type"]) {
    headers["Content-Type"] = "application/json";
  }
  const res = await fetch(path, { ...opts, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(data.detail || data.error || res.statusText);
    err.status = res.status;
    throw err;
  }
  return data;
}

function showApp() {
  gate.hidden = true;
  appEl.hidden = false;
  refresh();
  pollTimer = setInterval(refreshQuiet, 2500);
}

function showGate() {
  appEl.hidden = true;
  gate.hidden = false;
  if (pollTimer) clearInterval(pollTimer);
}

async function tryRestore() {
  if (!getKey()) return;
  try {
    await api("/api/sessions");
    showApp();
  } catch {
    clearKey();
  }
}

$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#login-error");
  err.hidden = true;
  const key = $("#admin-key").value.trim();
  try {
    setKey(key);
    await api("/api/login", { method: "POST", body: JSON.stringify({ key }) });
    showApp();
  } catch (ex) {
    clearKey();
    err.textContent = "Clé invalide";
    err.hidden = false;
  }
});

$("#btn-logout").addEventListener("click", () => {
  clearKey();
  currentId = null;
  showGate();
});

$("#btn-refresh").addEventListener("click", () => refresh());

$("#create-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("#new-name").value.trim();
  const platform = $("#new-platform").value;
  if (!name) return;
  const data = await api("/api/sessions", {
    method: "POST",
    body: JSON.stringify({ name, platform }),
  });
  $("#new-name").value = "";
  await refresh();
  selectAgent(data.session.id);
});

$("#btn-delete").addEventListener("click", async () => {
  if (!currentId) return;
  if (!confirm("Supprimer cet agent ? La machine se déconnectera au prochain poll.")) return;
  await api(`/api/sessions/${currentId}`, { method: "DELETE" });
  currentId = null;
  await refresh();
  renderStage();
});

document.querySelectorAll("[data-copy]").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const id = btn.getAttribute("data-copy");
    const text = document.getElementById(id).textContent;
    await navigator.clipboard.writeText(text);
    btn.textContent = "OK";
    setTimeout(() => (btn.textContent = "Copier"), 900);
  });
});

$("#run-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#run-input");
  const command = input.value.trim();
  if (!command || !currentId) return;
  input.value = "";
  appendTerm(`› ${command}`, "cmd-line");
  try {
    const queued = await api(`/api/sessions/${currentId}/enqueue`, {
      method: "POST",
      body: JSON.stringify({ command }),
    });
    const cmdId = queued.cmd_id;
    for (let i = 0; i < 60; i++) {
      await sleep(500);
      const data = await api(`/api/sessions/${currentId}`);
      const done = (data.session.history || []).find((h) => h.id === cmdId && h.done);
      if (done) {
        appendTerm(done.output || "(vide)");
        appendTerm(`exit ${done.exit_code}`, "muted");
        return;
      }
    }
    appendTerm("(en attente — rafraîchis si besoin)", "muted");
  } catch (ex) {
    appendTerm(String(ex.message || ex), "muted");
  }
});

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function appendTerm(text, cls) {
  const line = document.createElement("div");
  if (cls) line.className = cls;
  line.textContent = text;
  termOut.appendChild(line);
  termOut.scrollTop = termOut.scrollHeight;
}

async function refresh() {
  const data = await api("/api/sessions");
  sessions = data.sessions || [];
  renderList();
  if (currentId) {
    const s = sessions.find((x) => x.id === currentId);
    if (!s) {
      currentId = null;
      renderStage();
    } else {
      renderAgent(s);
    }
  } else {
    renderStage();
  }
}

async function refreshQuiet() {
  try {
    await refresh();
  } catch {
    /* ignore */
  }
}

function renderList() {
  agentList.innerHTML = "";
  if (!sessions.length) {
    agentList.innerHTML = `<li><p class="sub" style="padding:0.5rem;color:var(--muted)">Aucun agent</p></li>`;
    return;
  }
  for (const s of sessions) {
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.type = "button";
    if (s.id === currentId) btn.classList.add("active");
    btn.innerHTML = `
      <span class="name"><span class="dot ${s.online ? "on" : ""}"></span>${escapeHtml(s.name)}</span>
      <span class="sub">${s.online ? "en ligne" : "hors ligne"} · ${escapeHtml(s.platform || "any")}</span>
    `;
    btn.addEventListener("click", () => selectAgent(s.id));
    li.appendChild(btn);
    agentList.appendChild(li);
  }
}

function selectAgent(id) {
  currentId = id;
  const s = sessions.find((x) => x.id === id);
  renderList();
  renderStage();
  if (s) {
    termOut.innerHTML = "";
    const hist = s.history || [];
    for (const h of hist.slice(-30)) {
      if (h.command) appendTerm(`› ${h.command}`, "cmd-line");
      if (h.done) {
        appendTerm(h.output || "(vide)");
        appendTerm(`exit ${h.exit_code}`, "muted");
      }
    }
    renderAgent(s);
  }
}

function renderStage() {
  if (!currentId) {
    stageEmpty.hidden = false;
    stageAgent.hidden = true;
    return;
  }
  stageEmpty.hidden = true;
  stageAgent.hidden = false;
}

function renderAgent(s) {
  $("#agent-name").textContent = s.name;
  const st = $("#agent-status");
  st.textContent = s.online ? "● en ligne" : "○ hors ligne";
  st.classList.toggle("on", !!s.online);
  const a = s.agent || {};
  const bits = [a.hostname, a.user, a.os].filter(Boolean);
  $("#agent-meta").textContent = bits.length ? bits.join(" · ") : "En attente de première connexion…";
  $("#cmd-mac").textContent = s.one_liner_mac || "";
  $("#cmd-win").textContent = s.one_liner_win || "";
  $("#term-hint").textContent = s.online
    ? "Agent connecté — tape une commande"
    : "Installe l’agent sur la machine puis attends le statut en ligne";
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

tryRestore();
