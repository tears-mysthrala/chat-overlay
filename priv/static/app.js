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

    let currentProfiles = [];

    // OBS Management elements
    const obsProfileSelect = document.getElementById("obs-profile-select");
    const obsOverlayUrl = document.getElementById("obs-overlay-url");
    const copyObsLinkBtn = document.getElementById("copy-obs-link-btn");
    const obsCopyStatus = document.getElementById("obs-copy-status");
    const regenerateObsTokenBtn = document.getElementById("regenerate-obs-token-btn");
    const regenerateStatus = document.getElementById("regenerate-status");

    // Alerts & Multimedia elements
    const audioTypeExternal = document.getElementById("audio-type-external");
    const audioTypeUpload = document.getElementById("audio-type-upload");
    const audioExternalGroup = document.getElementById("audio-external-group");
    const audioUploadGroup = document.getElementById("audio-upload-group");
    const audioUrlInput = document.getElementById("audio-url-input");
    const audioFileInput = document.getElementById("audio-file-input");
    const audioFileInfo = document.getElementById("audio-file-info");
    const testAudioBtn = document.getElementById("test-audio-btn");
    const testAudioFeedback = document.getElementById("test-audio-feedback");

    const imageTypeExternal = document.getElementById("image-type-external");
    const imageTypeUpload = document.getElementById("image-type-upload");
    const imageExternalGroup = document.getElementById("image-external-group");
    const imageUploadGroup = document.getElementById("image-upload-group");
    const imageUrlInput = document.getElementById("image-url-input");
    const imageFileInput = document.getElementById("image-file-input");
    const imageFileInfo = document.getElementById("image-file-info");
    const imagePreviewImg = document.getElementById("image-preview-img");
    const previewNoneText = document.getElementById("preview-none-text");

    const saveAlertsBtn = document.getElementById("save-alerts-btn");
    const saveAlertsFeedback = document.getElementById("save-alerts-feedback");

    // Platform Accounts (OAuth 2.0 PKCE)
    const twitchStatusBadge = document.getElementById("twitch-status-badge");
    const twitchUserInfo = document.getElementById("twitch-user-info");
    const connectTwitchBtn = document.getElementById("connect-twitch-btn");
    const unlinkTwitchBtn = document.getElementById("unlink-twitch-btn");

    const youtubeStatusBadge = document.getElementById("youtube-status-badge");
    const youtubeUserInfo = document.getElementById("youtube-user-info");
    const connectYoutubeBtn = document.getElementById("connect-youtube-btn");
    const unlinkYoutubeBtn = document.getElementById("unlink-youtube-btn");

    const oauthFeedback = document.getElementById("oauth-feedback");

    function showOAuthFeedback(msg, type) {
      if (!oauthFeedback) return;
      oauthFeedback.hidden = false;
      oauthFeedback.className = `feedback-msg ${type}`;
      oauthFeedback.textContent = msg;
    }

    function getSelectedProfile() {
      if (!obsProfileSelect || !obsProfileSelect.value) return null;
      return currentProfiles.find(p => p.handle === obsProfileSelect.value) || null;
    }

    function syncProfileSelection() {
      const p = getSelectedProfile();
      if (!p) {
        if (obsOverlayUrl) obsOverlayUrl.value = "";
        return;
      }

      const cachedToken = sessionStorage.getItem(`obs_token_${p.handle}`);
      if (cachedToken) {
        obsOverlayUrl.value = `${location.origin}/overlay/${encodeURIComponent(p.handle)}?token=${encodeURIComponent(cachedToken)}`;
      } else if (p.has_capability_token) {
        obsOverlayUrl.value = `${location.origin}/overlay/${encodeURIComponent(p.handle)}?token=••••••••••••••••••••••••••••••••`;
      } else {
        obsOverlayUrl.value = `${location.origin}/overlay/${encodeURIComponent(p.handle)}`;
      }

      // Populate media
      const media = p.media || {};
      const sound = media.alert_sound;
      const img = media.alert_image;

      if (sound && sound.url) {
        audioUrlInput.value = sound.url;
        if (sound.source === "r2") {
          audioTypeUpload.checked = true;
          audioExternalGroup.hidden = true;
          audioUploadGroup.hidden = false;
        } else {
          audioTypeExternal.checked = true;
          audioExternalGroup.hidden = false;
          audioUploadGroup.hidden = true;
        }
      } else {
        audioUrlInput.value = "";
        audioTypeExternal.checked = true;
        audioExternalGroup.hidden = false;
        audioUploadGroup.hidden = true;
      }

      if (img && img.url) {
        imageUrlInput.value = img.url;
        imagePreviewImg.src = img.url;
        imagePreviewImg.hidden = false;
        previewNoneText.hidden = true;
        if (img.source === "r2") {
          imageTypeUpload.checked = true;
          imageExternalGroup.hidden = true;
          imageUploadGroup.hidden = false;
        } else {
          imageTypeExternal.checked = true;
          imageExternalGroup.hidden = false;
          imageUploadGroup.hidden = true;
        }
      } else {
        imageUrlInput.value = "";
        imagePreviewImg.hidden = true;
        previewNoneText.hidden = false;
        imageTypeExternal.checked = true;
        imageExternalGroup.hidden = false;
        imageUploadGroup.hidden = true;
      }

      // Populate linked platform accounts
      const linked = p.linked_accounts || {};
      const twitch = linked.twitch;
      const youtube = linked.youtube;

      if (twitch && twitch.linked) {
        if (twitch.status === "reauth_required") {
          if (twitchStatusBadge) {
            twitchStatusBadge.textContent = "Reautenticación requerida";
            twitchStatusBadge.className = "status-badge reauth-required";
          }
          if (twitchUserInfo) {
            twitchUserInfo.textContent = `Acceso expirado o revocado (@${twitch.username || twitch.user_id}). Vuelve a conectar.`;
          }
          if (connectTwitchBtn) {
            connectTwitchBtn.hidden = false;
            connectTwitchBtn.textContent = "Reconectar Twitch";
          }
          if (unlinkTwitchBtn) unlinkTwitchBtn.hidden = false;
        } else {
          if (twitchStatusBadge) {
            twitchStatusBadge.textContent = "Vinculado";
            twitchStatusBadge.className = "status-badge connected";
          }
          if (twitchUserInfo) {
            twitchUserInfo.textContent = `Conectado como @${twitch.username || twitch.user_id}`;
          }
          if (connectTwitchBtn) connectTwitchBtn.hidden = true;
          if (unlinkTwitchBtn) unlinkTwitchBtn.hidden = false;
        }
      } else {
        if (twitchStatusBadge) {
          twitchStatusBadge.textContent = "No vinculado";
          twitchStatusBadge.className = "status-badge disconnected";
        }
        if (twitchUserInfo) {
          twitchUserInfo.textContent = "Ninguna cuenta de Twitch vinculada a este perfil.";
        }
        if (connectTwitchBtn) {
          connectTwitchBtn.hidden = false;
          connectTwitchBtn.textContent = "Vincular Twitch";
        }
        if (unlinkTwitchBtn) unlinkTwitchBtn.hidden = true;
      }

      if (youtube && youtube.linked) {
        if (youtube.status === "reauth_required") {
          if (youtubeStatusBadge) {
            youtubeStatusBadge.textContent = "Reautenticación requerida";
            youtubeStatusBadge.className = "status-badge reauth-required";
          }
          if (youtubeUserInfo) {
            youtubeUserInfo.textContent = `Acceso expirado o revocado (${youtube.username || youtube.user_id}). Vuelve a conectar.`;
          }
          if (connectYoutubeBtn) {
            connectYoutubeBtn.hidden = false;
            connectYoutubeBtn.textContent = "Reconectar YouTube";
          }
          if (unlinkYoutubeBtn) unlinkYoutubeBtn.hidden = false;
        } else {
          if (youtubeStatusBadge) {
            youtubeStatusBadge.textContent = "Vinculado";
            youtubeStatusBadge.className = "status-badge connected";
          }
          if (youtubeUserInfo) {
            youtubeUserInfo.textContent = `Conectado como ${youtube.username || youtube.user_id}`;
          }
          if (connectYoutubeBtn) connectYoutubeBtn.hidden = true;
          if (unlinkYoutubeBtn) unlinkYoutubeBtn.hidden = false;
        }
      } else {
        if (youtubeStatusBadge) {
          youtubeStatusBadge.textContent = "No vinculado";
          youtubeStatusBadge.className = "status-badge disconnected";
        }
        if (youtubeUserInfo) {
          youtubeUserInfo.textContent = "Ninguna cuenta de Google/YouTube vinculada a este perfil.";
        }
        if (connectYoutubeBtn) {
          connectYoutubeBtn.hidden = false;
          connectYoutubeBtn.textContent = "Vincular YouTube";
        }
        if (unlinkYoutubeBtn) unlinkYoutubeBtn.hidden = true;
      }
    }

    function updateObsSelect(profiles) {
      if (!obsProfileSelect) return;
      const currentSelected = obsProfileSelect.value;
      obsProfileSelect.replaceChildren();

      if (profiles.length === 0) {
        const opt = document.createElement("option");
        opt.value = "";
        opt.textContent = "Ningún perfil configurado";
        obsProfileSelect.appendChild(opt);
        syncProfileSelection();
        return;
      }

      for (const p of profiles) {
        const opt = document.createElement("option");
        opt.value = p.handle;
        opt.textContent = p.handle;
        obsProfileSelect.appendChild(opt);
      }

      if (currentSelected && profiles.some(p => p.handle === currentSelected)) {
        obsProfileSelect.value = currentSelected;
      } else {
        obsProfileSelect.value = profiles[0].handle;
      }
      syncProfileSelection();
    }

    if (obsProfileSelect) {
      obsProfileSelect.addEventListener("change", syncProfileSelection);
    }

    if (audioTypeExternal && audioTypeUpload) {
      audioTypeExternal.addEventListener("change", () => {
        audioExternalGroup.hidden = false;
        audioUploadGroup.hidden = true;
      });
      audioTypeUpload.addEventListener("change", () => {
        audioExternalGroup.hidden = true;
        audioUploadGroup.hidden = false;
      });
    }

    if (imageTypeExternal && imageTypeUpload) {
      imageTypeExternal.addEventListener("change", () => {
        imageExternalGroup.hidden = false;
        imageUploadGroup.hidden = true;
      });
      imageTypeUpload.addEventListener("change", () => {
        imageExternalGroup.hidden = true;
        imageUploadGroup.hidden = false;
      });
    }

    if (imageUrlInput) {
      imageUrlInput.addEventListener("input", () => {
        const url = imageUrlInput.value.trim();
        if (url) {
          imagePreviewImg.src = url;
          imagePreviewImg.hidden = false;
          previewNoneText.hidden = true;
        } else {
          imagePreviewImg.hidden = true;
          previewNoneText.hidden = false;
        }
      });
    }

    if (imageFileInput) {
      imageFileInput.addEventListener("change", (e) => {
        const file = e.target.files && e.target.files[0];
        if (!file) return;
        if (file.name.toLowerCase().endsWith(".svg") || (file.type && file.type.includes("svg"))) {
          alert("Archivos SVG estrictamente prohibidos por seguridad (XSS en CEF de OBS).");
          imageFileInput.value = "";
          return;
        }
        if (file.size > 524288) {
          alert("La imagen excede el límite máximo de 512 KB.");
          imageFileInput.value = "";
          return;
        }
        if (imageFileInfo) {
          imageFileInfo.hidden = false;
          imageFileInfo.textContent = `${file.name} (${Math.round(file.size / 1024)} KB)`;
        }
        const objUrl = URL.createObjectURL(file);
        imagePreviewImg.src = objUrl;
        imagePreviewImg.hidden = false;
        previewNoneText.hidden = true;
      });
    }

    if (audioFileInput) {
      audioFileInput.addEventListener("change", (e) => {
        const file = e.target.files && e.target.files[0];
        if (!file) return;
        if (file.size > 2097152) {
          alert("El archivo de audio excede el límite máximo de 2 MB.");
          audioFileInput.value = "";
          return;
        }
        if (audioFileInfo) {
          audioFileInfo.hidden = false;
          audioFileInfo.textContent = `${file.name} (${Math.round(file.size / 1024)} KB)`;
        }
      });
    }

    if (testAudioBtn) {
      testAudioBtn.addEventListener("click", () => {
        let playUrl = null;
        if (audioTypeUpload && audioTypeUpload.checked && audioFileInput && audioFileInput.files && audioFileInput.files[0]) {
          playUrl = URL.createObjectURL(audioFileInput.files[0]);
        } else if (audioUrlInput) {
          playUrl = audioUrlInput.value.trim();
        }
        if (!playUrl) {
          if (testAudioFeedback) testAudioFeedback.textContent = "Introduce o selecciona un audio primero.";
          return;
        }
        if (testAudioFeedback) testAudioFeedback.textContent = "Reproduciendo sonido…";
        const audio = new Audio(playUrl);
        audio.play().then(() => {
          if (testAudioFeedback) {
            testAudioFeedback.textContent = "✓ Audio reproducido.";
            setTimeout(() => { testAudioFeedback.textContent = ""; }, 3000);
          }
        }).catch(() => {
          if (testAudioFeedback) testAudioFeedback.textContent = "⚠ Error al reproducir audio.";
        });
      });
    }

    if (copyObsLinkBtn) {
      copyObsLinkBtn.addEventListener("click", async () => {
        const url = obsOverlayUrl ? obsOverlayUrl.value : "";
        if (!url || url.includes("••••")) {
          if (url.includes("••••")) {
            alert("El token está oculto por seguridad. Haz clic en 'Regenerar enlace de OBS' para obtener uno nuevo visible y copiarlo.");
            return;
          }
          return;
        }
        try {
          await navigator.clipboard.writeText(url);
          if (obsCopyStatus) {
            obsCopyStatus.hidden = false;
            obsCopyStatus.textContent = "¡Enlace copiado al portapapeles!";
            setTimeout(() => { obsCopyStatus.hidden = true; }, 3000);
          }
        } catch {
          prompt("Copia el enlace de OBS:", url);
        }
      });
    }

    if (regenerateObsTokenBtn) {
      regenerateObsTokenBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;
        if (!confirm(`¿Regenerar el enlace de OBS para "${p.handle}"?\n\nLa fuente de navegador actual en OBS dejará de funcionar hasta que pegues el nuevo enlace.`)) {
          return;
        }
        try {
          regenerateObsTokenBtn.disabled = true;
          if (regenerateStatus) {
            regenerateStatus.hidden = false;
            regenerateStatus.className = "feedback-msg";
            regenerateStatus.textContent = "Regenerando capability token…";
          }

          const res = await fetch(`/api/profiles/${encodeURIComponent(p.handle)}/token/regenerate`, {
            method: "POST",
            headers: { "content-type": "application/json" }
          });
          const data = await res.json();
          if (res.ok && data.ok) {
            sessionStorage.setItem(`obs_token_${p.handle}`, data.token);
            const fullUrl = `${location.origin}${data.overlay_url}`;
            if (obsOverlayUrl) obsOverlayUrl.value = fullUrl;
            if (regenerateStatus) {
              regenerateStatus.className = "feedback-msg success";
              regenerateStatus.textContent = "¡Nuevo enlace generado con éxito! Cópialo y pégalo en OBS.";
            }
            await loadProfiles();
          } else {
            if (regenerateStatus) {
              regenerateStatus.className = "feedback-msg error";
              regenerateStatus.textContent = data.error || "No se pudo regenerar el enlace.";
            }
          }
        } catch {
          if (regenerateStatus) {
            regenerateStatus.className = "feedback-msg error";
            regenerateStatus.textContent = "Error de red al regenerar el enlace.";
          }
        } finally {
          regenerateObsTokenBtn.disabled = false;
        }
      });
    }

    if (saveAlertsBtn) {
      saveAlertsBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;

        if (saveAlertsFeedback) {
          saveAlertsFeedback.hidden = false;
          saveAlertsFeedback.className = "feedback-msg";
          saveAlertsFeedback.textContent = "Guardando alertas multimedia…";
        }
        saveAlertsBtn.disabled = true;

        try {
          let soundResult = null;
          let imageResult = null;

          // 1. Process Sound
          if (audioTypeUpload && audioTypeUpload.checked && audioFileInput && audioFileInput.files && audioFileInput.files[0]) {
            const file = audioFileInput.files[0];
            if (saveAlertsFeedback) saveAlertsFeedback.textContent = "Solicitando subida a Cloudflare R2 para audio…";
            const presignRes = await fetch("/api/media/presign", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                handle: p.handle,
                filename: file.name,
                content_type: file.type || "audio/mpeg",
                size: file.size
              })
            });
            const presignData = await presignRes.json();
            if (!presignRes.ok || !presignData.ok) {
              throw new Error(presignData.error || "Error al solicitar subida de audio a R2");
            }

            if (saveAlertsFeedback) saveAlertsFeedback.textContent = "Subiendo audio directamente a Cloudflare R2…";
            const uploadRes = await fetch(presignData.upload_url, {
              method: "PUT",
              body: file,
              headers: { "Content-Type": file.type || "audio/mpeg" }
            });
            if (!uploadRes.ok) {
              throw new Error("Fallo al subir el archivo de audio a R2");
            }
            soundResult = { url: presignData.public_url, source: "r2" };
          } else if (audioUrlInput && audioUrlInput.value.trim()) {
            soundResult = { url: audioUrlInput.value.trim(), source: "external" };
          } else {
            soundResult = { url: "", source: "external" };
          }

          // 2. Process Image
          if (imageTypeUpload && imageTypeUpload.checked && imageFileInput && imageFileInput.files && imageFileInput.files[0]) {
            const file = imageFileInput.files[0];
            if (file.name.toLowerCase().endsWith(".svg") || (file.type && file.type.includes("svg"))) {
              throw new Error("Archivos SVG estrictamente prohibidos por seguridad (XSS en CEF)");
            }
            if (saveAlertsFeedback) saveAlertsFeedback.textContent = "Solicitando subida a Cloudflare R2 para imagen…";
            const presignRes = await fetch("/api/media/presign", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                handle: p.handle,
                filename: file.name,
                content_type: file.type || "image/png",
                size: file.size
              })
            });
            const presignData = await presignRes.json();
            if (!presignRes.ok || !presignData.ok) {
              throw new Error(presignData.error || "Error al solicitar subida de imagen a R2");
            }

            if (saveAlertsFeedback) saveAlertsFeedback.textContent = "Subiendo imagen directamente a Cloudflare R2…";
            const uploadRes = await fetch(presignData.upload_url, {
              method: "PUT",
              body: file,
              headers: { "Content-Type": file.type || "image/png" }
            });
            if (!uploadRes.ok) {
              throw new Error("Fallo al subir el archivo de imagen a R2");
            }
            imageResult = { url: presignData.public_url, source: "r2" };
          } else if (imageUrlInput && imageUrlInput.value.trim()) {
            imageResult = { url: imageUrlInput.value.trim(), source: "external" };
          } else {
            imageResult = { url: "", source: "external" };
          }

          // 3. Save to profile
          const mediaPayload = {};
          if (soundResult) mediaPayload.alert_sound = soundResult;
          if (imageResult) mediaPayload.alert_image = imageResult;

          const res = await fetch(`/api/profiles/${encodeURIComponent(p.handle)}/media`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(mediaPayload)
          });
          const data = await res.json();
          if (res.ok && data.ok) {
            if (saveAlertsFeedback) {
              saveAlertsFeedback.className = "feedback-msg success";
              saveAlertsFeedback.textContent = "¡Alertas multimedia guardadas con éxito!";
            }
            await loadProfiles();
          } else {
            throw new Error(data.error || "Error al guardar alertas en el perfil");
          }
        } catch (err) {
          if (saveAlertsFeedback) {
            saveAlertsFeedback.className = "feedback-msg error";
            saveAlertsFeedback.textContent = err.message || "Error al guardar alertas.";
          }
        } finally {
          saveAlertsBtn.disabled = false;
        }
      });
    }

    async function loadProfiles() {
      try {
        const res = await fetch("/api/profiles");
        if (!res.ok) throw new Error("Error cargando perfiles");
        const data = await res.json();
        currentProfiles = data.profiles || [];
        renderProfiles(currentProfiles);
        updateObsSelect(currentProfiles);
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
          const cachedToken = sessionStorage.getItem(`obs_token_${profile.handle}`);
          const fullUrl = cachedToken
            ? `${location.origin}${profile.overlay_url}?token=${encodeURIComponent(cachedToken)}`
            : `${location.origin}${profile.overlay_url}`;
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
            const platforms = (data.profile.sources || []).map(s => s.platform);
            if (platforms.includes("twitch") && platforms.includes("youtube")) {
              msg += " Feed unificada con Twitch y YouTube.";
            } else if (data.profile.sources && data.profile.sources.length > 1) {
              msg += " Feed unificada con múltiples fuentes.";
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

    if (connectTwitchBtn) {
      connectTwitchBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;
        try {
          const urlParams = new URLSearchParams(location.search);
          const token = urlParams.get("token") || sessionStorage.getItem(`obs_token_${p.handle}`);
          const tokenQuery = token ? `&token=${encodeURIComponent(token)}` : "";
          const res = await fetch(`/api/oauth/authorize/twitch?handle=${encodeURIComponent(p.handle)}${tokenQuery}`);
          const data = await res.json();
          if (data.ok && data.url) {
            location.assign(data.url);
          } else {
            showOAuthFeedback(data.error || "Error al generar enlace de autorización", "error");
          }
        } catch {
          showOAuthFeedback("Error de conexión al iniciar autorización de Twitch", "error");
        }
      });
    }

    if (unlinkTwitchBtn) {
      unlinkTwitchBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;
        if (!confirm(`¿Desvincular la cuenta de Twitch del perfil "${p.handle}"?`)) return;
        try {
          const res = await fetch(`/api/profiles/${encodeURIComponent(p.handle)}/unlink/twitch`, {
            method: "POST",
            headers: { "content-type": "application/json" }
          });
          const data = await res.json();
          if (data.ok) {
            showOAuthFeedback("Cuenta de Twitch desvinculada con éxito.", "success");
            await loadProfiles();
          } else {
            showOAuthFeedback(data.error || "Error al desvincular", "error");
          }
        } catch {
          showOAuthFeedback("Error de red al desvincular", "error");
        }
      });
    }

    if (connectYoutubeBtn) {
      connectYoutubeBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;
        try {
          const urlParams = new URLSearchParams(location.search);
          const token = urlParams.get("token") || sessionStorage.getItem(`obs_token_${p.handle}`);
          const tokenQuery = token ? `&token=${encodeURIComponent(token)}` : "";
          const res = await fetch(`/api/oauth/authorize/youtube?handle=${encodeURIComponent(p.handle)}${tokenQuery}`);
          const data = await res.json();
          if (data.ok && data.url) {
            location.assign(data.url);
          } else {
            showOAuthFeedback(data.error || "Error al generar enlace de autorización", "error");
          }
        } catch {
          showOAuthFeedback("Error de conexión al iniciar autorización de YouTube", "error");
        }
      });
    }

    if (unlinkYoutubeBtn) {
      unlinkYoutubeBtn.addEventListener("click", async () => {
        const p = getSelectedProfile();
        if (!p) return;
        if (!confirm(`¿Desvincular la cuenta de YouTube del perfil "${p.handle}"?`)) return;
        try {
          const res = await fetch(`/api/profiles/${encodeURIComponent(p.handle)}/unlink/youtube`, {
            method: "POST",
            headers: { "content-type": "application/json" }
          });
          const data = await res.json();
          if (data.ok) {
            showOAuthFeedback("Cuenta de YouTube desvinculada con éxito.", "success");
            await loadProfiles();
          } else {
            showOAuthFeedback(data.error || "Error al desvincular", "error");
          }
        } catch {
          showOAuthFeedback("Error de red al desvincular", "error");
        }
      });
    }

    const dashboardParams = new URLSearchParams(window.location.search);
    if (dashboardParams.has("linked")) {
      const prov = dashboardParams.get("linked");
      showOAuthFeedback(`¡Cuenta de ${prov.toUpperCase()} vinculada exitosamente!`, "success");
    } else if (dashboardParams.has("error")) {
      const err = dashboardParams.get("error");
      const msgMap = {
        identity_mismatch: "La cuenta autenticada no coincide con el titular del canal.",
        unauthorized_profile_claim: "Reclamación no autorizada: titularidad no acreditada.",
        oauth_failed: "Error durante el proceso de autenticación OAuth.",
        profile_not_found: "Perfil no encontrado para completar la vinculación."
      };
      showOAuthFeedback(msgMap[err] || `Aviso de autorización: ${err}`, "error");
    }

    async function loadSession() {
      const banner = document.getElementById("session-banner");
      const statusText = document.getElementById("session-status-text");
      const logoutBtn = document.getElementById("session-logout-btn");
      if (!banner || !statusText || !logoutBtn) return;

      try {
        const res = await fetch("/api/auth/me");
        if (!res.ok) return;
        const data = await res.json();
        if (data.ok && data.authenticated) {
          statusText.textContent = `Sesión activa: ${data.handle} (${data.provider})`;
          banner.hidden = false;
          logoutBtn.addEventListener("click", async () => {
            logoutBtn.disabled = true;
            try {
              await fetch("/api/auth/logout", {
                method: "POST",
                headers: { "content-type": "application/json" }
              });
              location.reload();
            } catch {
              logoutBtn.disabled = false;
            }
          });
        }
      } catch {
        // Mode offline or without session
      }
    }

    loadSession();
    loadProfiles();
  }

  const [, view, handle] = location.pathname.split("/");
  const overlay = view === "overlay";
  if (overlay) document.body.classList.add("overlay");
  const demo = document.body.dataset.demo === "true";
  document.getElementById("demo-notice").hidden = !demo;
  document.getElementById("profile-name").textContent = handle;
  document.title = `${handle} · Chat Overlay`;
  const urlParams = new URLSearchParams(location.search);
  const token = urlParams.get("token");
  const overlayURL = `${location.origin}/overlay/${encodeURIComponent(handle)}${token ? `?token=${encodeURIComponent(token)}` : ""}`;
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
  const streamQuery = new URLSearchParams({ view: overlay ? "overlay" : "reader" });
  if (token) streamQuery.set("token", token);
  const stream = new EventSource(`/events/${encodeURIComponent(handle)}?${streamQuery.toString()}`);
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
