// Every key the Inbox answers, once. This table runs the handlers
// (useShortcuts), fills the key list (KeyHelp) and puts the key caps on the
// controls, so a key cannot be listed and not work, or work and go unlisted.
//
// `does` is the page's handlers and `is` what is true just now.
export const GROUPS = ["Navigation", "Actions", "Reply and compose", "Selection"]

export function mailBindings(does, is) {
  const reading = () => !is.composing()
  return [
    { id: "next", group: "Navigation", label: "Next conversation", keys: ["j", "ArrowDown"], repeat: true, run: () => does.step(1) },
    { id: "previous", group: "Navigation", label: "Previous conversation", keys: ["k", "ArrowUp"], repeat: true, run: () => does.step(-1) },
    { id: "open", group: "Navigation", label: "Open, or reply when open", keys: ["Enter"], run: does.enter },
    { id: "open-only", group: "Navigation", label: "Open", keys: ["o"], run: does.open },
    { id: "back", group: "Navigation", label: "Clear the selection, or go back", keys: ["Escape"], run: does.back },
    { id: "page-down", group: "Navigation", label: "Scroll the conversation down", keys: ["Space"], repeat: true, when: reading, run: () => does.scroll(1) },
    { id: "page-up", group: "Navigation", label: "Scroll the conversation up", keys: ["Shift+Space"], repeat: true, when: reading, run: () => does.scroll(-1) },

    { id: "archive", group: "Actions", label: "Archive", keys: ["e"], when: reading, run: () => does.archive() },
    { id: "unread", group: "Actions", label: "Mark unread and go back", keys: ["u"], when: reading, run: does.markUnread },
    { id: "read", group: "Actions", label: "Mark read", keys: ["Shift+I"], when: reading, run: does.markRead },
    { id: "undo", group: "Actions", label: "Undo", keys: ["z", "Mod+z"], run: does.undo },
    { id: "help", group: "Actions", label: "Show or hide this list", keys: ["?"], dialog: true, run: does.help },

    { id: "reply", group: "Reply and compose", label: "Reply", keys: ["r"], when: reading, run: does.reply },
    { id: "send", group: "Reply and compose", label: "Send", keys: ["Mod+Enter"], typing: true, when: is.writing, run: () => does.send({ archive: false }) },
    { id: "send-archive", group: "Reply and compose", label: "Send a reply and archive", keys: ["Mod+Shift+Enter"], typing: true, when: is.replying, run: () => does.send({ archive: true }) },
    { id: "compose", group: "Reply and compose", label: "New conversation", keys: ["c"], run: does.compose },

    { id: "select", group: "Selection", label: "Select or deselect", keys: ["x"], when: reading, run: does.select },
    { id: "extend-down", group: "Selection", label: "Extend the selection down", keys: ["Shift+J", "Shift+ArrowDown"], repeat: true, when: reading, run: () => does.extend(1) },
    { id: "extend-up", group: "Selection", label: "Extend the selection up", keys: ["Shift+K", "Shift+ArrowUp"], repeat: true, when: reading, run: () => does.extend(-1) },
    { id: "select-all", group: "Selection", label: "Select every conversation", keys: ["Mod+a"], when: reading, run: does.selectAll },
  ]
}

// The first key of a binding, for the cap on its control.
export const keyOf = (bindings, id) => bindings.find((binding) => binding.id === id)?.keys[0]
