import Foundation

/// The script every page of a hybrid app runs. It reads the page's
/// `data-native-*` elements, says what they ask for whenever that changes,
/// and is the `window.RubyNative` the ruby_native gem's helpers call. It runs
/// in the page's own world, because those helpers call it from `onclick`.
enum HybridBridge {
    static let caller = "instantRecordCall"
    static let handler = "instantRecordHybrid"

    static let script = #"""
    (() => {
      if (window.instantRecordHybrid) return
      const post = message => window.webkit.messageHandlers.instantRecordHybrid.postMessage(message)
      const has = (el, name) => el.hasAttribute("data-native-" + name)
      const get = (el, name) => el.getAttribute("data-native-" + name)
      const truthy = (el, name) => has(el, name) && get(el, name) !== "false"
      const find = name => document.querySelector(`[data-native-${name}]`)

      const item = el => ({
        title: get(el, "title") || "", icon: get(el, "icon") || "",
        href: get(el, "href"), click: get(el, "click"),
        inTitle: get(el, "position") === "title",
        leading: ["leading", "left"].includes(get(el, "position")),
        selected: truthy(el, "selected"), destructive: truthy(el, "destructive"),
        replace: get(el, "action") === "replace",
        share: has(el, "share"), shareURL: get(el, "share-url"),
        items: [...el.querySelectorAll("[data-native-menu-item]")].map(item)
      })

      const navbar = () => {
        const bar = find("navbar")
        if (!bar) return null
        const all = name => [...bar.querySelectorAll(`[data-native-${name}]`)].map(item)
        const title = get(bar, "navbar") || (get(bar, "navbar-title") === "false" ? "" : document.title)
        return {
          title, pullToRefresh: get(bar, "pull-to-refresh") !== "false",
          buttons: all("button"), segments: all("segment"), submit: all("submit-button")[0] || null
        }
      }

      const fab = () => {
        const el = find("fab")
        return el && { ...item(el), color: get(el, "color") }
      }

      const badges = () => {
        try {
          const said = JSON.parse(get(find("badge-tabs"), "badge-tabs"))
          return Object.fromEntries(Object.entries(said).filter(([, value]) => value !== null).map(([key, value]) => [key, String(value)]))
        } catch { return {} }
      }

      // Shown once: the element stops being a toast as it is read, so a page
      // that comes back from the cache does not show it again.
      const toast = () => {
        const el = find("toast-message")
        if (!el) return null
        const said = { message: get(el, "toast-message"), icon: get(el, "toast-icon") }
        el.remove()
        return said
      }

      let places = []
      const opensNative = url => url.origin === location.origin && places.find(place => place.pattern.test(url.pathname))?.page === false

      let canGoBack = false
      const mark = () => {
        // Only a real change is written: a write is a mutation, and the
        // observer would answer it with another, for ever.
        const root = document.documentElement
        if (root && !root.hasAttribute("data-native-app")) root.setAttribute("data-native-app", "")
        const body = document.body
        if (body && body.classList.contains("can-go-back") !== canGoBack) body.classList.toggle("can-go-back", canGoBack)
      }

      let last = ""
      const gather = () => {
        mark()
        const badge = find("badge-tab")
        const signals = {
          url: location.href, tabs: !!find("tabs"), form: !!find("form"), navbar: navbar(), fab: fab(),
          badge: badge && get(badge, "badge-tab"), badges: badges(), toast: toast()
        }
        const text = JSON.stringify(signals)
        if (text === last) return
        last = signals.toast ? "" : text
        post({ type: "signals", signals: text })
      }

      let waiting = false
      const soon = () => {
        if (waiting || document.readyState === "loading") return
        waiting = true
        queueMicrotask(() => { waiting = false; gather() })
      }

      window.instantRecordHybrid = {
        gather() { last = ""; gather() },
        routes(patterns) { places = patterns.map(place => ({ ...place, pattern: new RegExp(place.pattern) })) },
        back(can) { canGoBack = can; mark() },
        click(selector) { document.querySelector(selector)?.click() },
        visit(url, replace) {
          if (window.Turbo?.visit) window.Turbo.visit(url, { action: replace ? "replace" : "advance" })
          else if (replace) location.replace(url)
          else location.assign(url)
        }
      }

      // Methods of Ruby Native's that this shell does not have do nothing.
      const known = {
        postMessage(message) { if (message?.action === "back") post({ type: "back" }) },
        visit(url, options) { post({ type: "visit", url: String(url), replace: options?.action === "replace" }) },
        share(options) { post({ type: "share", url: String(options?.url || location.href) }) }
      }
      window.RubyNative = new Proxy(known, { get: (target, name) => target[name] ?? (name === "then" ? undefined : () => {}) })

      window.InstantRecord = Object.freeze({
        call: (name, args = {}) => window.webkit.messageHandlers.instantRecordCall.postMessage({ name, arguments: args })
      })

      document.addEventListener("click", event => {
        const el = event.target?.closest?.("[data-native-haptic]")
        if (el) post({ type: "haptic", feedback: get(el, "haptic") || "success" })
      }, true)

      // Ahead of Turbo and Inertia, which would otherwise fetch the page.
      window.addEventListener("click", event => {
        const link = event.target?.closest?.("a[href]")
        if (!link || event.defaultPrevented || event.button > 0 || link.dataset.turboMethod || link.dataset.method || link.hasAttribute("download")) return
        if (link.getAttribute("href").startsWith("#") || !opensNative(new URL(link.href))) return
        event.preventDefault()
        event.stopImmediatePropagation()
        post({ type: "visit", url: link.href })
      }, true)

      mark()
      document.addEventListener("DOMContentLoaded", gather)
      window.addEventListener("pageshow", event => { if (event.persisted) window.instantRecordHybrid.gather() })
      new MutationObserver(soon).observe(document, { subtree: true, childList: true, attributes: true, characterData: true })
    })()
    """#
}
