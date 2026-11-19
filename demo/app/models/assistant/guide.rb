module Assistant
  # The scripted answers. They stand in whenever no model is configured, the
  # day's budget is spent, or a model call fails.
  module Guide
    def self.reply(prompt)
      case prompt
      when /checklist|test plan|regression/i
        "Regression checklist\n\n- Send an item online and confirm a second profile receives it.\n- Disconnect, edit a draft, and reload the tab.\n- Reconnect and confirm the saved change appears exactly once."
      when /trace|timeline|missing email/i
        "Delivery trace\n\n1. The sender writes to local SQLite.\n2. The worker posts its pending mutation to Rails.\n3. Rails appends an inbox revision in PostgreSQL.\n4. The teammate polls past that revision and renders the subject."
      when /diff|patch/i
        "To limit the first page of an inbox, order before applying the limit.\n\n```diff\n- messages.to_a\n+ messages.order(created_at: :desc, id: :desc).limit(50).to_a\n```\n\nUse both columns in the next page’s cursor."
      when /compare|trade.?off/i
        "Offset pagination is convenient for jumping to a page number. Inserts ahead of that offset can repeat or skip rows.\n\nA keyset cursor uses the last row’s ordered values. It is a better fit for an inbox receiving new messages while you scroll."
      when /workspace|todo|how many|inspect/i
        total = Issue.count
        done = Issue.where(state: "done").count
        "The server workspace has #{total} todos: #{total - done} open and #{done} completed."
      when /query|ruby|rails|code/i
        <<~TEXT.strip
          To find the five newest open todos, filter before you sort and limit the results.

          ```ruby
          Issue.where(state: "open")
               .order(created_at: :desc)
               .limit(5)
               .pluck(:title)
          ```

          This returns just the titles.
        TEXT
      when /offline|sync|outbox/i
        "A Todo write commits locally and adds a mutation to the outbox. Once the connection returns, the worker sends pending mutations to Rails.\n\nThe Assistant answers on both sides of the connection: online it asks Rails, and offline it can answer from a model in your browser."
      else
        "I’m the scripted Rails demo guide. Ask me to inspect the workspace, explain offline sync, show a Rails query, trace delivery, compare pagination methods, or write a test checklist."
      end
    end
  end
end
