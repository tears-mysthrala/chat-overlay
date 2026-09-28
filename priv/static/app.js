"use strict";
(() => {
  const dashboard = document.getElementById("dashboard");
  if (dashboard) {
    initDashboard();
    return;
  }

  const form = document.getElementById("open-profile");
  if (form) {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const handle = document.getElementById("handle").value.trim().toLowerCase();
      if (/^[a-z0-9][a-z0-9_-]{0,39}$/.test(handle)) location.assign(`/reader/${encodeURIComponent(handle)}`);
    });
    return;
  }

  function initDashboard() {
    const profilesList = document.getElementById("profiles-list");
    const emptyProfiles = document.getElementById("empty-profiles");
    const loadingProfiles = document.getElementById("loading-profiles");
    const addForm = document.getElementById("add-channel-form");
    const targetInput = document.getElementById("target-input");
    const platformSelect = document.getElementById("platform-select");
    const customHandleInput = document.getElementById("custom-handle-input");
    const submitBtn = document.getElementById("submit-btn");
    const feedbackArea = document.getElementById("feedback-area");
    const openForm = document.getElementById("open-profile");

    if (openForm) {
      openForm.addEventListener("submit", (e) => {
        e.preventDefault();
        const handle = document.getElementById("handle").value.trim().toLowerCase();
        if (/^[a-z0-9][a-z0-9_-]{0,39}$/.test(handle)) {
          location.assign(`/reader/${encodeURIComponent(handle)}`);
        }
      });
    }

    function showFeedback(message, type) {
      if (!feedbackArea) return;
      feedbackArea.hidden = false;
      feedbackArea.className = `feedback-msg ${type}`;
      feedbackArea.textContent = message;
    }

    function hideFeedback() {
      if (!feedbackArea) return;
      feedbackArea.hidden = true;
      feedbackArea.className = "feedback-msg";
      feedbackArea.textContent = "";
    }

    async function loadProfiles() {
      try {
        const res = await fetch("/api/profiles");
        if (!res.ok) throw new Error("Error cargando perfiles");
        const data = await res.json();
        renderProfiles(data.profiles || []);
      } catch {
        if (loadingProfiles) loadingProfiles.textContent = "Error al conectar con la API.";
      }
    }

    function renderProfiles(profiles) {
      if (loadingProfiles) loadingProfiles.hidden = true;
      if (!profilesList) return;
      profilesList.replaceChildren();

      if (profiles.length === 0) {
        if (emptyProfiles) emptyProfiles.hidden = false;
        return;
      }

      if (emptyProfiles) emptyProfiles.hidden = true;

      for (const profile of profiles) {
        const card = document.createElement("div");
        card.className = "profile-card";

        const info = document.createElement("div");
        info.className = "profile-info";

        const handleSpan = document.createElement("span");
        handleSpan.className = "profile-handle";
        handleSpan.textContent = profile.handle;
        info.appendChild(handleSpan);

        const badges = document.createElement("div");
        badges.className = "platform-badges";
        for (const plat of (profile.platforms || [])) {
          const badge = document.createElement("span");
          badge.className = `platform-badge badge-${plat}`;
          badge.textContent = plat;
          badges.appendChild(badge);
        }
        info.appendChild(badges);

        if (profile.linked_youtube) {
          const ytHint = document.createElement("span");
          ytHint.className = "linked-yt-hint";
          const hasYt = (profile.platforms || []).includes("youtube");
          ytHint.textContent = hasYt
            ? `YouTube unificado: ${profile.linked_youtube}`
            : `YouTube vinculado: ${profile.linked_youtube}`;
          info.appendChild(ytHint);
        }

        const actions = document.createElement("div");
        actions.className = "profile-actions";

        const readerLink = document.createElement("a");
        readerLink.href = profile.reader_url;
        readerLink.className = "btn-action btn-primary";
        readerLink.textContent = "Abrir Lector";

        const copyBtn = document.createElement("button");
        copyBtn.type = "button";
        copyBtn.className = "btn-action";
        copyBtn.textContent = "Copiar Overlay OBS";
        copyBtn.addEventListener("click", async () => {
          const fullUrl = `${location.origin}${profile.overlay_url}`;
          try {
            await navigator.clipboard.writeText(fullUrl);
            copyBtn.textContent = "¡Copiado!";
            setTimeout(() => { copyBtn.textContent = "Copiar Overlay OBS"; }, 2000);
          } catch {
            prompt("Copia la URL del overlay:", fullUrl);
          }
        });

        const deleteBtn = document.createElement("button");
        deleteBtn.type = "button";
        deleteBtn.className = "btn-action btn-danger";
        deleteBtn.textContent = "Eliminar";
        deleteBtn.addEventListener("click", async () => {
          if (!confirm(`¿Eliminar el perfil "${profile.handle}"?`)) return;
          try {
            deleteBtn.disabled = true;
            const res = await fetch(`/api/profiles/${encodeURIComponent(profile.handle)}`, { method: "DELETE" });
            const data = await res.json();
            if (data.ok) {
              await loadProfiles();
            } else {
              alert(data.error || "No se pudo eliminar el perfil");
            }
          } catch {
            alert("Error de red al eliminar el perfil");
          } finally {
            deleteBtn.disabled = false;
          }
        });

        if (profile.linked_youtube) {
          const isYtConnected = (profile.platforms || []).includes("youtube");
          const syncYtBtn = document.createElement("button");
          syncYtBtn.type = "button";
          syncYtBtn.className = "btn-action btn-sync-yt";
          const btnLabel = isYtConnected ? "↻ Resincronizar YouTube" : "▶ Sincronizar YouTube";
          syncYtBtn.textContent = btnLabel;
          syncYtBtn.addEventListener("click", async () => {
            try {
              syncYtBtn.disabled = true;
              syncYtBtn.textContent = "Buscando directo…";
              const res = await fetch(`/api/profiles/${encodeURIComponent(profile.handle)}/sync-youtube`, {
                method: "POST",
                headers: { "content-type": "application/json" }
              });
              const data = await res.json();
              if (res.ok && data.ok) {
                showFeedback(
                  isYtConnected
                    ? `¡Directo de YouTube actualizado con éxito para "${profile.handle}"!`
                    : `¡Directo de YouTube sincronizado con éxito para "${profile.handle}"!`,
                  "success"
                );
                await loadProfiles();
              } else {
                alert(data.error || "No se pudo sincronizar el directo de YouTube.");
              }
            } catch {
              alert("Error de red al sincronizar el directo de YouTube.");
            } finally {
              syncYtBtn.disabled = false;
              syncYtBtn.textContent = btnLabel;
            }
          });
          actions.appendChild(syncYtBtn);
        }

        actions.append(readerLink, copyBtn, deleteBtn);
        card.append(info, actions);
        profilesList.appendChild(card);
      }
    }

    if (addForm) {
      addForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        hideFeedback();

        const target = targetInput.value.trim();
        const handle = customHandleInput.value.trim();
        const platform = platformSelect ? platformSelect.value : "auto";

        if (!target) return;

        if (submitBtn) {
          submitBtn.disabled = true;
          submitBtn.textContent = "Resolviendo canal en directo…";
        }

        try {
          const payload = { target };
          if (handle) payload.handle = handle;
          if (platform !== "auto") payload.platform = platform;

          const res = await fetch("/api/profiles", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(payload)
          });

          const data = await res.json();

          if (res.ok && data.ok) {
            let msg = `¡Canal añadido con éxito como "${data.profile.handle}"!`;
            if (data.profile.sources && data.profile.sources.length > 1) {
              msg += " Feed unificada con Twitch y YouTube.";
            } else if (data.profile.linked_youtube) {
              msg += ` Se detectó canal de YouTube vinculado (${data.profile.linked_youtube}) sin directo activo; podrás sincronizarlo con un clic cuando inicie emisión.`;
            }
            showFeedback(msg, "success");
            targetInput.value = "";
            customHandleInput.value = "";
            if (platformSelect) platformSelect.value = "auto";
            await loadProfiles();
          } else {
            showFeedback(data.error || "Error al añadir el canal", "error");
          }
        } catch {
          showFeedback("Error de comunicación con el servidor.", "error");
        } finally {
          if (submitBtn) {
            submitBtn.disabled = false;
            submitBtn.textContent = "Añadir Canal en Caliente";
          }
        }
      });
    }

    loadProfiles();
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
    const frags = payload.fragments;
    if (!Array.isArray(frags) || frags.length === 0 || frags.length > 100) {
      container.textContent = payload.text;
      return;
    }
    for (const frag of frags) {
      if (!frag || typeof frag !== "object") continue;
      const text = typeof frag.text === "string" ? frag.text : "";
      if (frag.type === "emote" && typeof frag.id === "string") {
        const url = emoteURL(frag.id, platform);
        if (url) {
          const img = document.createElement("img");
          img.src = url;
          img.alt = text;
          img.title = text;
          img.className = "emote";
          img.width = 28;
          img.height = 28;
          img.loading = "lazy";
          img.draggable = false;
          container.appendChild(img);
        } else {
          container.appendChild(document.createTextNode(text));
        }
      } else {
        container.appendChild(document.createTextNode(text));
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
