"use strict";

// CI-only driver; interactive local evidence uses the native T3 preview.
if (process.env.GITHUB_ACTIONS !== "true") {
  console.error("Browser runner requires GitHub Actions; use native preview locally.");
  process.exit(2);
}
const { chromium } = require("playwright");
const { mkdirSync, writeFileSync } = require("node:fs");
const checks = require("./browser_checks.js");
const origin = "http://localhost:4143";
const evidence = { passed: false, scenarios: [] };
let stage = "launch";
let browser;
function report() {
  mkdirSync("output/browser", { recursive: true });
  writeFileSync("output/browser/result.json", JSON.stringify({ ...evidence, stage }, null, 2) + "\n");
}
const deadline = setTimeout(() => {
  stage = "deadline";
  report();
  console.error("Synthetic browser checks exceeded 180 seconds.");
  process.exit(1);
}, 180_000);

(async () => {
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
    evidence.browser = browser.version();
    for (const viewport of [{ width: 1280, height: 800 }, { width: 390, height: 844 }]) {
      const context = await browser.newContext({ viewport, serviceWorkers: "block" });
      let externalRequests = 0;
      let pageErrors = 0;
      try {
        // Never log request URLs: OAuth state and capability tokens are secret data.
        await context.route("**/*", route => {
          if (new URL(route.request().url()).origin === origin) return route.continue();
          externalRequests++;
          return route.abort("blockedbyclient");
        });
        await context.routeWebSocket("**/*", socket => {
          externalRequests++;
          socket.close();
        });
        await context.addInitScript(() => {
          window.__browserCspViolations = 0;
          document.addEventListener("securitypolicyviolation", () => window.__browserCspViolations++);
        });
        const page = await context.newPage();
        page.on("pageerror", () => pageErrors++);
        page.setDefaultTimeout(10_000);
        page.setDefaultNavigationTimeout(15_000);
        stage = `${viewport.width}:login`;
        await page.goto(origin, { waitUntil: "domcontentloaded" });
        const login = await page.evaluate(checks, "login");
        if (login.login !== true) throw new Error("login");
        await page.reload({ waitUntil: "domcontentloaded" });
        stage = `${viewport.width}:verify`;
        const result = await page.evaluate(checks, "verify");
        const cspViolations = await page.evaluate(() => window.__browserCspViolations);
        stage = `${viewport.width}:logout`;
        await Promise.all([
          page.waitForEvent("domcontentloaded"),
          page.locator("#session-logout-btn").click()
        ]);
        stage = `${viewport.width}:logged-out-checks`;
        const logout = await page.evaluate(checks, "logged-out");
        evidence.scenarios.push({ viewport, login, checks: result, logout, pageErrors, cspViolations, externalRequests });
        stage = `${viewport.width}:runtime-and-isolation`;
        if (pageErrors || cspViolations || externalRequests) throw new Error("browser isolation or runtime failure");
      } finally {
        await context.close();
      }
    }
    evidence.passed = true;
    stage = "complete";
    console.log("Synthetic browser checks passed: desktop and mobile.");
  } catch {
    // Playwright error stacks can embed request URLs or DOM values; omit them.
    console.error(`Synthetic browser checks failed at ${stage}; sensitive diagnostics omitted.`);
    process.exitCode = 1;
  } finally {
    report();
    if (browser) await browser.close();
    clearTimeout(deadline);
  }
})();
