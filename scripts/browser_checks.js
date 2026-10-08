// Evaluate this function in the native preview on the isolated browser_fixture server.
// Run ('login'), reload the page, run ('verify'), then click logout and run ('logged-out').
// Uses synthetic fixtures only; returns booleans/statuses, never tokens or signed URLs.
/** Run one isolated fixture stage, including anonymous access, load failures and private-link recovery.
 * @param {string} stage Scenario stage selected by the browser driver.
 * @returns {Promise<object>} Assertions recorded as evidence; rejects when a check fails.
 */
async function f2BrowserChecks(stage) {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const wait = async (predicate) => {
    for (let n = 0; n < 50; n++) {
      if (predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error("UI did not settle within five seconds");
  };
  assert(location.hostname === "localhost" && location.port === "4143", "Isolated fixture origin required");
  if (stage === "load-error") {
    await wait(() => !document.getElementById("retry-dashboard").hidden);
    assert(document.getElementById("dashboard").hidden, "Private controls shown after load failure");
    assert(document.querySelector(".dashboard-nav").hidden, "Private navigation shown after load failure");
    assert(!document.getElementById("signin-section").hidden, "Sign-in unavailable after load failure");
    assert(!document.getElementById("dashboard-load-status").hidden, "Load failure explanation missing");
    return { loadFailureHidden: true, recoveryAvailable: true };
  }
  if (stage === "anonymous") {
    await wait(() => !document.getElementById("signin-section").hidden);
    assert(document.getElementById("dashboard").hidden, "Private controls shown without session");
    assert(document.querySelector(".dashboard-nav").hidden, "Private navigation shown without session");
    assert(document.getElementById("signin-form").checkValidity() === false, "Profile required for sign-in");
    const handle = document.getElementById("signin-handle");
    handle.value = "MyChannel";
    assert(handle.checkValidity(), "Mixed-case profile rejected before normalization");
    handle.value = "";
    assert(!document.body.innerText.includes("Error al conectar con la API"), "Signed-out state treated as API error");
    assert(document.documentElement.scrollWidth <= innerWidth, "Anonymous horizontal overflow");
    return { signedOutState: true, privateControlsHidden: true };
  }
  if (stage === "login") {
    const auth = await (await fetch("/api/oauth/authorize/twitch?handle=alice")).json();
    assert(auth.ok, "Synthetic OAuth start failed");
    const state = new URL(auth.url).searchParams.get("state");
    const result = await fetch("/oauth/callback/twitch?code=synthetic&state=" + encodeURIComponent(state));
    assert(result.ok, "Synthetic OAuth callback failed");
    return { login: (await (await fetch("/api/auth/me")).json()).authenticated };
  }
  if (stage === "logged-out") {
    const me = await (await fetch("/api/auth/me")).json();
    assert(!me.authenticated, "Session remains authenticated");
    assert(!Object.keys(sessionStorage).some(k => k.startsWith("obs_token_")), "Capability copy remains after logout");
    assert(document.getElementById("session-banner").hidden, "Authenticated UI remains after logout");
    return { logout: true, capabilityCopiesRemoved: true };
  }
  assert(stage === "verify", "Unknown stage");
  await wait(() => document.querySelector("#obs-profile-select option"));
  const handles = [...document.querySelectorAll("#obs-profile-select option")].map(x => x.value);
  assert(JSON.stringify(handles) === '["alice"]', "Profile isolation failed in UI");
  assert(!document.cookie.includes("chat_overlay_session"), "Session cookie exposed to script");
  if (!sessionStorage.getItem("obs_token_alice")) {
    const manage = document.querySelector('#profiles-list button[data-action="obs-link"][data-profile-handle="alice"]');
    assert(manage, "Missing OBS management action without cached capability");
    const input = document.getElementById("obs-overlay-url");
    assert(input.value === "" || input.value.includes("••••"), "Tokenless URL advertised as private");
    manage.click();
    assert(document.activeElement.id === "regenerate-obs-token-btn", "OBS management did not focus next action");
    assert(!document.getElementById("obs-copy-status").hidden, "Missing private-link recovery explanation");
  }

  const forbidden = await fetch("/api/profiles/bob/media", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  assert(forbidden.status === 403, "Cross-profile mutation allowed");
  for (const id of ["audio-type-upload", "image-type-upload", "audio-file-input", "image-file-input"]) {
    assert(document.getElementById(id).disabled, "Upload permission missing in UI: " + id);
  }
  assert(!document.getElementById("upload-permission-note").hidden, "Permission explanation hidden");
  document.getElementById("audio-url-input").value = "http://example.invalid/alert.mp3";
  document.getElementById("save-alerts-btn").click();
  await wait(() => document.getElementById("save-alerts-feedback").textContent.includes("HTTPS"));
  assert(!document.getElementById("save-alerts-btn").disabled, "Recoverable error left UI disabled");
  const confirmBefore = window.confirm;
  window.confirm = () => true; // Deliberately accept only this synthetic test's confirmation.
  try {
    const input = document.getElementById("obs-overlay-url");
    let old = input.value;
    document.getElementById("regenerate-obs-token-btn").click();
    await wait(() => input.value !== old && !document.getElementById("regenerate-obs-token-btn").disabled);
    old = input.value;
    assert((await fetch(old)).status === 200, "New overlay URL rejected");
    const streamUrl = new URL(old);
    streamUrl.pathname = "/events/alice";
    streamUrl.searchParams.set("view", "overlay");
    const controller = new AbortController();
    const stream = await fetch(streamUrl, { signal: controller.signal });
    assert(stream.status === 200, "SSE denied with capability");
    const first = await stream.body.getReader().read();
    assert(new TextDecoder().decode(first.value).includes("retry:"), "SSE did not begin");
    controller.abort();
    document.getElementById("regenerate-obs-token-btn").click();
    await wait(() => input.value !== old && !document.getElementById("regenerate-obs-token-btn").disabled);
    assert((await fetch(old)).status === 401, "Previous capability not revoked");
    assert((await fetch(input.value)).status === 200, "Replacement capability rejected");
    assert((await fetch("/overlay/alice")).status === 401, "Missing capability accepted");
  } finally { window.confirm = confirmBefore; }
  assert(document.documentElement.scrollWidth <= innerWidth, "Horizontal overflow");
  return { profileIsolation: true, httpOnly: true, crossProfileStatus: 403, permissions: true, recoverableMediaError: true, regeneration: true, revocation: true, sse: true, width: innerWidth, noHorizontalOverflow: true, userAgent: navigator.userAgent };
}

// Import the same function in CI; native preview can still evaluate it directly.
if (typeof module !== "undefined") module.exports = f2BrowserChecks;
