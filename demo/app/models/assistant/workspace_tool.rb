module Assistant
  # Lets the model read the demo's todo counts instead of guessing them.
  class WorkspaceTool < RubyLLM::Tool
    description "Counts the todos in this demo's server workspace: total, open and done."

    def name = "workspace_todos"

    def execute
      total = Issue.count
      done = Issue.where(state: "done").count
      { total: total, open: total - done, done: done }
    end
  end
end
