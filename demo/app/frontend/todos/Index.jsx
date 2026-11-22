import { router } from "@inertiajs/react"
import { useState } from "react"

// Every write is drawn twice: once here, at once, as a guess at what the
// server will say, and once more when the server's props come back. A row
// that is still a guess has no id the server knows, so it takes no clicks
// until the answer arrives.
export default function Index({ todos }) {
  const [title, setTitle] = useState("")
  const keep = { preserveScroll: true, preserveState: true }

  const add = (event) => {
    event.preventDefault()
    const guess = { id: `guess-${Date.now()}`, title, state: "open", pending: true }
    router
      .optimistic((props) => ({ todos: [guess, ...props.todos] }))
      .post("/inertia/todos", { todo: { title } }, keep)
    setTitle("")
  }

  const toggle = (todo) => {
    const state = todo.state === "done" ? "open" : "done"
    router
      .optimistic((props) => ({ todos: props.todos.map((each) => (each.id === todo.id ? { ...each, state } : each)) }))
      .patch(`/inertia/todos/${todo.id}`, { done: state === "done" ? "1" : "" }, keep)
  }

  const remove = (todo) => {
    router
      .optimistic((props) => ({ todos: props.todos.filter((each) => each.id !== todo.id) }))
      .delete(`/inertia/todos/${todo.id}`, keep)
  }

  return (
    <main className="four">
      <div className="card">
        <form className="four-form" onSubmit={add}>
          <input type="text" value={title} onChange={(event) => setTitle(event.target.value)}
            placeholder="Add a todo and press Enter" aria-label="New todo" required autoFocus />
          <input type="submit" value="Add" />
        </form>

        <ul className="four-list" data-controller="stopwatch">
          {todos.map((todo) => (
            <li key={todo.id} data-id={todo.id} className={[todo.state, todo.pending && "pending"].filter(Boolean).join(" ")}>
              <div className="four-toggle">
                <input type="checkbox" id={`todo-${todo.id}`} checked={todo.state === "done"}
                  disabled={todo.pending} onChange={() => toggle(todo)} />
                <label htmlFor={`todo-${todo.id}`}>{todo.title}</label>
              </div>
              <button type="button" aria-label="Delete" disabled={todo.pending} onClick={() => remove(todo)}>×</button>
            </li>
          ))}
        </ul>
      </div>
    </main>
  )
}
