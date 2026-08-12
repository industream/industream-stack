/*
 * Industream Hub Bridge — Grafana plugin module
 *
 * Hand-written AMD module (no build step). Loaded by Grafana SystemJS when
 * preload:true on every Grafana page.
 *
 * Runs INSIDE the Grafana iframe. The Grafana iframe is same-origin with the
 * wrapper page (nginx reverse-proxies /grafana/* to Grafana on the same host).
 * The wrapper relays postMessage between Hub shell and this plugin.
 *
 * Protocol (with the wrapper, same-origin):
 *   plugin -> wrapper:
 *     { id: 'industream-hub/v1/route',        path }
 *     { id: 'industream-hub/v1/set-theme',    payload: { variant } }
 *     { id: 'industream-hub/v1/theme-requested', payload: { variant, path } }
 *   wrapper -> plugin (forwarded from Hub):
 *     { id: 'industream-hub/v1/set-theme',    payload: { variant } }
 *     { id: 'industream-hub/v1/navigate',     path }
 *     { id: 'industream-hub/v1/back' }
 *     { id: 'industream-hub/v1/forward' }
 */
define(["@grafana/data", "@grafana/runtime"], function (data, runtime) {
  "use strict";

  var AppPlugin = data.AppPlugin;
  var locationService = runtime.locationService;
  var config = runtime.config;

  var LOG_PREFIX = "[industream-hub-bridge]";
  var lastBroadcastedPath = null;

  function currentThemeVariant() {
    // URL param wins: the wrapper sets ?theme=<variant> on every iframe
    // reload, so the URL reflects the intended theme even before Grafana's
    // bootData/config are fully populated. Avoids race conditions at boot.
    try {
      var urlTheme = new URLSearchParams(window.location.search).get("theme");
      if (urlTheme === "light" || urlTheme === "dark") return urlTheme;
    } catch (e) {
      // URLSearchParams not available — fall through.
    }
    try {
      if (config && config.theme2 && typeof config.theme2.isDark === "boolean") {
        return config.theme2.isDark ? "dark" : "light";
      }
      if (config && config.bootData && config.bootData.user) {
        return config.bootData.user.lightTheme ? "light" : "dark";
      }
    } catch (e) {
      // Defensive — config shape varies between Grafana versions.
    }
    return "dark";
  }

  function postToWrapper(message) {
    // window.parent is the wrapper page — same origin (nginx reverse-proxy).
    try {
      window.parent.postMessage(message, window.location.origin);
    } catch (e) {
      console.warn(LOG_PREFIX, "postToWrapper failed", e);
    }
  }

  function broadcastRoute(path) {
    if (path === lastBroadcastedPath) return;
    lastBroadcastedPath = path;
    postToWrapper({ id: "industream-hub/v1/route", path: path });
  }

  function subscribeToRouteChanges() {
    if (!locationService) return;
    var observable = null;
    if (typeof locationService.getLocationObservable === "function") {
      try { observable = locationService.getLocationObservable(); } catch (e) {}
    }
    if (observable && typeof observable.subscribe === "function") {
      observable.subscribe(function (loc) {
        if (loc && typeof loc.pathname === "string") {
          broadcastRoute(loc.pathname + (loc.search || ""));
        }
      });
    } else {
      window.addEventListener("popstate", function () {
        broadcastRoute(window.location.pathname + window.location.search);
      });
    }
  }

  function handleHubMessage(event) {
    // Wrapper is same-origin. It already filtered messages by Hub origin
    // before forwarding to us — same-origin check here is defence in depth.
    if (event.origin !== window.location.origin) return;
    var msg = event.data;
    if (!msg || typeof msg.id !== "string") return;

    if (msg.id === "industream-hub/v1/set-theme" && msg.payload) {
      var variant = msg.payload.variant;
      if (variant !== "dark" && variant !== "light") return;
      if (variant === currentThemeVariant()) return;
      // Delegate the reload to the wrapper. The wrapper has the JWT and can
      // rebuild the iframe URL with ?theme=<variant>&auth_token=<JWT>, which
      // re-authenticates and applies the theme on next render.
      postToWrapper({
        id: "industream-hub/v1/theme-requested",
        payload: {
          variant: variant,
          path: window.location.pathname + window.location.search,
        },
      });
    } else if (msg.id === "industream-hub/v1/navigate" && typeof msg.path === "string") {
      try {
        locationService.push(msg.path);
      } catch (e) {
        console.warn(LOG_PREFIX, "navigate failed", e);
      }
    } else if (msg.id === "industream-hub/v1/back") {
      window.history.back();
    } else if (msg.id === "industream-hub/v1/forward") {
      window.history.forward();
    } else if (msg.id === "industream-hub/v1/auth-logout") {
      showLogoutOverlay();
    }
  }

  function showLogoutOverlay() {
    if (document.getElementById("industream-hub-logout-overlay")) return;
    console.log(LOG_PREFIX, "auth lost — rendering session-expired overlay");

    var overlay = document.createElement("div");
    overlay.id = "industream-hub-logout-overlay";
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;" +
      "align-items:center;justify-content:center;background:#181b1f;color:#ccc;" +
      "font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;gap:0.75rem;";

    var heading = document.createElement("div");
    heading.style.cssText = "font-size:1.25rem;font-weight:600;";
    heading.textContent = "Session expired";

    var hint = document.createElement("div");
    hint.style.cssText = "opacity:0.7;max-width:24rem;text-align:center;";
    hint.textContent = "Sign back in via the Industream Hub to continue.";

    overlay.appendChild(heading);
    overlay.appendChild(hint);
    document.body.appendChild(overlay);
  }

  function bootstrap() {
    console.log(LOG_PREFIX, "starting; theme=" + currentThemeVariant() + " path=" + window.location.pathname);
    subscribeToRouteChanges();
    window.addEventListener("message", handleHubMessage);

    // Initial route broadcast only — the Hub is the source of truth for the
    // theme (sticky broadcast delivers the current global theme to us on
    // subscribe). Broadcasting our local theme here would race with Hub state
    // and risk overriding it back to whatever Grafana booted with.
    broadcastRoute(window.location.pathname + window.location.search);
  }

  // Defer slightly so Grafana's router/store mount before we subscribe.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bootstrap);
  } else {
    setTimeout(bootstrap, 50);
  }

  function NoopRootPage() {
    return null;
  }

  return {
    plugin: new AppPlugin().setRootPage(NoopRootPage),
  };
});
