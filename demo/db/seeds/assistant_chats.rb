# The conversations the Assistant demo ships with. Fixed ids keep the routine
# idempotent. Each chat opens with a long scripted history, so there is
# something to scroll back through, and ends with the turns in assistant_chats.json.
module AssistantChats
  STARTED = Time.utc(2026, 1, 1)

  # A case is four related turns of earlier history.
  CASES = {
    "chat-scrollback" => [
      ["Variable-height rows", "A long code block makes the fourth row twice as tall.", "Remember a visible message and its offset inside the pane.", "Insert a code block above the reader and compare the same row before and after."],
      ["Delayed history", "The older page comes back two seconds after the reader moved.", "Take the anchor measurement immediately before insertion.", "Scroll down while a request is pending. The late response should preserve the new reading position."],
      ["Repeated scroll events", "A trackpad fires several top-edge events in a single gesture.", "Allow one pending request per conversation and cursor.", "Count requests for one cursor while holding Page Up."],
      ["Identical timestamps", "Two messages at the page boundary share a creation time.", "Use the timestamp and the stable row ID together as the cursor.", "Put equal timestamps on either side of a boundary and compare the distinct IDs."],
      ["Switching threads", "A slow response for Design arrives while Support is open.", "Apply the page only to the conversation that requested it.", "Open a second thread during a slow load and check its first visible message."],
      ["Failed page load", "The connection drops before the oldest page arrives.", "Keep the current boundary intact and expose a retry.", "Disconnect, request more, reconnect, and fetch the same cursor once."],
      ["Following new replies", "A reply lands while someone is reading the middle of a long exchange.", "Only follow new replies automatically from the bottom.", "Test an arrival at the bottom and another three screens above it."],
      ["Keyboard navigation", "A reader uses Page Up and cannot use the mouse wheel.", "Give the transcript its own focusable scroll region and a load control.", "Reach the first turn and return to Latest using only the keyboard."]
    ],
    "inbox-delivery" => [
      ["Two recipients", "The sender sees a new subject but the other teammate sees an empty list.", "Separate a local commit from the server acknowledgment.", "Read the subject from an independently opened teammate profile."],
      ["A duplicate reply", "A retry arrives after the first POST already committed.", "Reuse the original mutation ID when retrying.", "Count replies after posting the same mutation twice."],
      ["Mailbox boundaries", "A member can switch between Support and Billing.", "Derive the feed from the authorized mailbox on every request.", "Open both inboxes and verify a test conversation appears only in its target."],
      ["An older conversation", "A useful ticket is hundreds of messages below the newest one.", "Page through conversation IDs, then load their associated replies.", "Open a ticket on the second page and verify its complete thread."],
      ["Server rejection", "A write looks valid locally but Rails refuses to store it.", "Use the mutation acknowledgment to explain the failed write.", "Reject one mutation and verify that the other teammate never receives it."],
      ["Archiving", "A teammate archives a conversation while its reader is still open.", "Update inbox membership when the archive event arrives.", "Keep two lists open and observe the subject disappear from both."],
      ["A compose draft", "Incoming mail changes the list while someone is typing.", "Refresh the list without replacing the active form.", "Type a subject, generate an incoming message, and check the input value."],
      ["Returning offline", "Someone reopens a previously visited inbox without a connection.", "Read cached mail locally and distinguish missing history from an empty mailbox.", "Open a cached thread and compare it with a page never fetched before."]
    ],
    "offline-todos" => [
      ["First local write", "The network is slow but the user expects the new issue immediately.", "Commit the issue and its outbox entry together.", "Read the new issue before allowing the mutation POST to complete."],
      ["Toggle twice", "Two clicks change the same issue before either acknowledgment arrives.", "Track both operations independently.", "Delay the first response and verify the newer checkbox state survives."],
      ["Tab closed", "A browser tab closes just after a local write.", "Persist the database snapshot together with its pending changes.", "Reload offline and inspect both the issue and the pending count."],
      ["Conflicting edits", "Two tabs update an issue while disconnected.", "Reconcile from the stored revision when another tab commits.", "Reconnect in reverse order and compare both lists."],
      ["Rollback", "A server validation rejects a locally accepted title.", "Remove or restore the affected record according to the rejected operation.", "Verify unrelated local changes persist after rejection."],
      ["A new device", "A second browser profile has no local database yet.", "Bootstrap from the server, then consume newer changes.", "Compare the fresh list with a teammate after all pending writes drain."],
      ["Counting open work", "A count disagrees with the visible filtered list.", "Use the same state predicate for the count and the rows.", "Create three open issues, close one, and check both displays."],
      ["Interrupted delivery", "A reply is lost between Rails committing and the tab receiving it.", "Keep the original mutation identity across retries.", "Interrupt the connection after commit and confirm the issue appears exactly once."]
    ]
  }.freeze

  def self.apply
    chats = JSON.parse(File.read(File.join(__dir__, "assistant_chats.json")))
    chats.each_with_index do |chat, position|
      id = chat.fetch("id")
      # Newest first in the list, so the first example leads it.
      started = STARTED + (chats.size - position).days
      AssistantChat.create!(id: id, title: chat.fetch("title"), created_at: started) unless AssistantChat.exists?(id: id)
      (history(id) + chat.fetch("turns")).each_with_index do |(prompt, reply), index|
        turn_id = "#{id}-#{format('%03d', index)}"
        next if AssistantTurn.exists?(id: turn_id)
        AssistantTurn.create!(id: turn_id, assistant_chat_id: id, prompt: prompt, reply: reply,
          author: "Demo guide", created_at: started + index.minutes)
      end
    end
  end

  def self.history(id)
    CASES.fetch(id).flat_map do |topic, symptom, action, check|
      [["What would you investigate in the #{topic.downcase} case?", symptom],
        ["How should we handle that?", action],
        ["Give me a regression check for #{topic.downcase}.", check],
        ["Summarize that case for the review.", "Review checklist\n\n- Reproduce: #{symptom}\n- Change: #{action}\n- Verify: #{check}"]]
    end
  end
end
