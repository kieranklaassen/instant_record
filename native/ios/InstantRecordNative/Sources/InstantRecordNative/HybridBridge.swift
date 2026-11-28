import Foundation

/// The script every page of a hybrid app runs. It reads the page's
/// `data-native` elements (InstantRecord::NativeHelper), says what they ask
/// for whenever that changes, and is the page's `window.InstantRecord`.
enum HybridBridge {
    static let caller = "instantRecordCall"
    static let handler = "instantRecordHybrid"

    static let script = #"""
    (() => {
      if (window.instantRecordHybrid) return
      const post = message => window.webkit.messageHandlers.instantRecordHybrid.postMessage(message)
      // What the page's elements say, put together. A toast is said once: its
      // element goes as it is read, so a page back from the cache is silent.
      const said = () => {
        const all = { badges: {} }
        document.querySelectorAll("[data-native]").forEach(el => {
          let part
          try { part = JSON.parse(el.getAttribute("data-native")) } catch { return }
          if (part.toast) el.remove()
          Object.assign(all, part, { badges: { ...all.badges, ...part.badges } })
        })
        if (all.navbar && !all.navbar.title && !all.navbar.buttons?.some(button => button.inTitle)) all.navbar = { ...all.navbar, title: document.title }
        return all
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
        const { tabs, form, navbar, fab, badges, toast } = said()
        const signals = { url: location.href, tabs: !!tabs, form: !!form, navbar: navbar || null, fab: fab || null, badges, toast: toast || null }
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

      window.InstantRecord = Object.freeze({
        back() { post({ type: "back" }) },
        visit(url, options) { post({ type: "visit", url: String(url), replace: options?.replace === true }) },
        share(url) { post({ type: "share", url: String(url || location.href) }) },
        call: (name, args = {}) => window.webkit.messageHandlers.instantRecordCall.postMessage({ name, arguments: args })
      })

      document.addEventListener("click", event => {
        const el = event.target?.closest?.("[data-native-haptic]")
        if (el) post({ type: "haptic", feedback: el.getAttribute("data-native-haptic") || "success" })
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
