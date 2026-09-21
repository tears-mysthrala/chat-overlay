"use strict";
(() => {
  const form = document.getElementById("open-profile");
  if (form) {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const handle = document.getElementById("handle").value;
      if (/^[a-z0-9][a-z0-9_-]{0,39}$/.test(handle)) location.assign(`/reader/${encodeURIComponent(handle)}`);
    });
    return;
  }
  const [, view, handle] = location.pathname.split("/");
  const overlay = view === "overlay";
  if (overlay) document.body.classList.add("overlay");
  const demo = document.body.dataset.demo === "true";
  document.getElementById("demo-notice").hidden = !demo;
  document.getElementById("profile-name").textContent = handle;
  document.title = `${handle} · Chat Overlay`;
  const overlayURL = `${location.origin}/overlay/${encodeURIComponent(handle)}`;
  document.getElementById("open-overlay").href = overlayURL;
  document.getElementById("copy-overlay").addEventListener("click", async () => {
    const status = document.getElementById("copy-status");
    try { await navigator.clipboard.writeText(overlayURL); status.textContent = "URL copiada."; }
    catch { status.textContent = `Copia esta URL: ${overlayURL}`; }
  });
  let messages = [], states = new Map(), connected = false, follow = true;
  const list = document.getElementById("messages");
  const labels = {twitch: "Twitch", youtube: "YouTube", kick: "Kick"};
  const statusLabels = {connecting: "Conectando", available: "Disponible", offline: "Sin actividad", degraded: "Sin confirmar", configuration_error: "Revisar configuración"};
  const sourceKey = e => JSON.stringify([e.platform, e.channel]);
  const key = e => JSON.stringify([e.platform, e.channel, e.emission_session, e.payload.message_id]);
  const sameSource = (a, b) => sourceKey(a) === sourceKey(b);
  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const EMOTE_ID_RE = /^[a-zA-Z0-9_\-:]+$/;
  const emoteURL = (id, platform) => {
    if (!EMOTE_ID_RE.test(id) || id.length > 256) return null;
    if (platform === "twitch") return `https://static-cdn.jtvnw.net/emoticons/v2/${encodeURIComponent(id)}/default/dark/1.0`;
    return null;
  };
  const renderBody = (container, payload, platform) => {
    if (!Array.isArray(payload.fragments) || payload.fragments.length === 0) {
      container.textContent = payload.text;
      return;
    }
    for (const frag of payload.fragments) {
      if (frag.type === "emote" && frag.id) {
        const url = emoteURL(frag.id, platform);
        if (url) {
          const img = document.createElement("img");
          img.src = url;
          img.alt = frag.text || "";
          img.title = frag.text || "";
          img.className = "emote";
          img.width = 28;
          img.height = 28;
          img.loading = "lazy";
          img.draggable = false;
          container.appendChild(img);
        } else {
          container.appendChild(document.createTextNode(frag.text || ""));
        }
      } else {
        container.appendChild(document.createTextNode(frag.text || ""));
      }
    }
  };
  document.getElementById("follow").addEventListener("click", event => {
    follow = !follow;
    event.target.setAttribute("aria-pressed", String(follow));
    event.target.textContent = follow ? "Seguimiento activado" : "Seguimiento pausado";
    if (follow) list.scrollTop = list.scrollHeight;
  });
  function apply(e) {
    switch (e.event) {
      case "reset": messages = []; states.clear(); break;
      case "snapshot": messages = e.payload.messages; states = new Map(e.payload.source_states.map(s => [sourceKey(s), s])); break;
      case "message": messages = messages.filter(m => key(m) !== key(e)); messages.push(e); break;
      case "replace": {
        const replacement = {...e, event: "message", payload: e.payload.message};
        messages = messages.map(m => key(m) === key(replacement) ? replacement : m); break;
      }
      case "delete_message": messages = messages.filter(m => key(m) !== key(e)); break;
      case "delete_author": messages = messages.filter(m => !(sameSource(m, e) && m.payload.author_id === e.payload.author_id)); break;
      case "clear_channel": messages = messages.filter(m => !sameSource(m, e)); break;
      case "source_state": states.set(sourceKey(e), e); break;
    }
    messages = messages.slice(-100);
  }
  function renderStatus() {
    const target = document.getElementById("source-status");
    const nodes = [], problems = [];
    for (const s of states.values()) {
      const age = Math.max(0, Math.floor((Date.now() - Date.parse(s.payload.observed_at)) / 1000));
      const state = s.payload.state === "available" && age > 120 ? "degraded" : s.payload.state;
      const row = element("div", "source"); row.dataset.platform = s.platform;
      row.append(element("strong", "", labels[s.platform]), element("span", "", statusLabels[state]));
      row.append(element("small", "", `Última comprobación: hace ${age < 60 ? `${age} s` : `${Math.floor(age/60)} min`}`));
      nodes.push(row);
      if (state !== "available") problems.push(`${labels[s.platform]}: ${statusLabels[state].toLowerCase()}`);
    }
    target.replaceChildren(...nodes);
    document.getElementById("connection").textContent = connected ? "Vista conectada" : "Reconectando con el servicio…";
    document.getElementById("overlay-state").textContent = demo ? "Demostración · mensajes sintéticos" : (!connected ? "Reconectando…" : problems.join(" · "));
  }
  function render() {
    messages = messages.filter(m => Date.now() - Date.parse(m.received_at) < 1800000);
    const nodes = messages.map(m => {
      const item = element("li", "message"); item.dataset.platform = m.platform;
      const meta = element("div", "message-meta");
      meta.append(element("span", "platform", labels[m.platform]), element("bdi", "author", m.payload.author_display));
      const time = element("time", "", new Date(m.received_at).toLocaleTimeString("es", {hour:"2-digit", minute:"2-digit"}));
      time.dateTime = m.received_at; meta.append(time);
      const body = element("p");
      renderBody(body, m.payload, m.platform);
      item.append(meta, body); return item;
    });
    const scroll = list.scrollTop;
    list.replaceChildren(...nodes);
    list.scrollTop = (follow || overlay) ? list.scrollHeight : scroll;
    document.getElementById("empty").hidden = messages.length > 0;
    document.getElementById("message-count").textContent = `${messages.length} mensajes`;
    renderStatus();
  }
  const stream = new EventSource(`/events/${encodeURIComponent(handle)}?view=${overlay ? "overlay" : "reader"}`);
  stream.onopen = () => { connected = true; renderStatus(); };
  stream.onerror = () => { connected = false; renderStatus(); };
  stream.addEventListener("batch", event => {
    try {
      const batch = JSON.parse(event.data);
      if (!Array.isArray(batch.events) || batch.events.length > 512) throw new Error("Invalid batch");
      for (const e of batch.events) apply(e);
      render();
    } catch {
      stream.close(); connected = false; renderStatus();
      document.getElementById("connection").textContent = "No se pudo actualizar el chat. Recarga la vista.";
    }
  });
  const clock = setInterval(() => {
    if (messages.some(m => Date.now() - Date.parse(m.received_at) >= 1800000)) render();
    else renderStatus();
  }, 10000);
  window.addEventListener("pageshow", event => { if (event.persisted) location.reload(); });
  window.addEventListener("pagehide", () => { clearInterval(clock); stream.close(); }, {once:true});
})();
