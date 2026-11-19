import assert from "node:assert/strict"
import { test } from "node:test"
import { chord, keycaps, match } from "./chord.js"

const press = (key, modifiers = {}) => ({ key, ...modifiers })
const mac = { apple: true }
const pc = { apple: false }

test("a letter is named in lower case, and with Shift in upper case", () => {
  assert.equal(chord(press("j"), pc), "j")
  assert.equal(chord(press("J"), pc), "j")
  assert.equal(chord(press("J", { shiftKey: true }), pc), "Shift+J")
})

test("Mod is Command on a Mac and Control elsewhere", () => {
  assert.equal(chord(press("Enter", { metaKey: true }), mac), "Mod+Enter")
  assert.equal(chord(press("Enter", { ctrlKey: true }), pc), "Mod+Enter")
  assert.equal(chord(press("Enter", { ctrlKey: true }), mac), null)
  assert.equal(chord(press("Enter", { metaKey: true, shiftKey: true }), mac), "Mod+Shift+Enter")
})

test("a shifted symbol is named by the symbol alone", () => {
  assert.equal(chord(press("?", { shiftKey: true }), pc), "?")
})

test("Space and its shifted form have names", () => {
  assert.equal(chord(press(" "), pc), "Space")
  assert.equal(chord(press(" ", { shiftKey: true }), pc), "Shift+Space")
})

test("Alt names nothing, so it matches no binding", () => {
  assert.equal(chord(press("j", { altKey: true }), pc), null)
  assert.equal(match([{ keys: ["j"] }], press("j", { altKey: true }), null, pc), null)
})

test("a binding that does not apply passes the key to the next one", () => {
  const off = { keys: ["e"], when: () => false }
  const on = { keys: ["e"] }
  assert.equal(match([off, on], press("e"), null, pc), on)
})

test("while typing, only a binding marked for it runs", () => {
  const field = { tagName: "TEXTAREA" }
  const plain = { keys: ["Mod+Enter"] }
  const marked = { keys: ["Mod+Enter"], typing: true }
  assert.equal(match([plain], press("Enter", { ctrlKey: true }), field, pc), null)
  assert.equal(match([plain, marked], press("Enter", { ctrlKey: true }), field, pc), marked)
})

test("a button keeps Enter and Space, and other keys still run", () => {
  const button = { tagName: "BUTTON" }
  const checkbox = { tagName: "INPUT", type: "checkbox" }
  const bindings = [{ keys: ["Enter", "Space"] }, { keys: ["j"] }]
  assert.equal(match(bindings, press("Enter"), button, pc), null)
  assert.equal(match(bindings, press(" "), checkbox, pc), null)
  assert.equal(match(bindings, press("j"), button, pc), bindings[1])
  assert.equal(match(bindings, press("j"), checkbox, pc), bindings[1])
})

test("inside a dialog only a binding marked for it runs", () => {
  const inside = { tagName: "DIV", closest: () => ({}) }
  const help = { keys: ["?"], dialog: true }
  assert.equal(match([{ keys: ["j"] }, help], press("j"), inside, pc), null)
  assert.equal(match([{ keys: ["j"] }, help], press("?", { shiftKey: true }), inside, pc), help)
})

test("a held key repeats only a binding marked for it", () => {
  const archive = { keys: ["e"] }
  const down = { keys: ["j"], repeat: true }
  assert.equal(match([archive], press("e", { repeat: true }), null, pc), null)
  assert.equal(match([down], press("j", { repeat: true }), null, pc), down)
})

test("key caps follow the platform", () => {
  assert.deepEqual(keycaps("Mod+Shift+Enter", mac), ["⌘", "⇧", "↵"])
  assert.deepEqual(keycaps("Mod+Shift+Enter", pc), ["Ctrl", "Shift", "↵"])
  assert.deepEqual(keycaps("Shift+J", pc), ["Shift", "J"])
  assert.deepEqual(keycaps("Escape", pc), ["Esc"])
})

test("a keydown with no key, as autofill sends, names nothing", () => {
  assert.equal(chord({}, pc), null)
})
