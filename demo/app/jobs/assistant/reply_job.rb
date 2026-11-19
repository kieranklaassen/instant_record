module Assistant
  # Answers a turn that asked the server. Enqueued by a server_only callback on
  # AssistantTurn, so it runs for a turn posted to Rails and for one that a
  # browser saved offline and synced later.
  class ReplyJob < ApplicationJob
    queue_as :default

    # What the model is given as context: the last answered turns, each text clipped.
    HISTORY_TURNS = 6
    HISTORY_TEXT = 2_000
    # Visitors' conversations are shared by every browser, so the oldest make room.
    KEPT_CHATS = 40

    def perform(turn_id)
      turn = AssistantTurn.find_by(id: turn_id)
      return if turn.nil? || turn.answered?

      answer = Reply.call(prompt: turn.prompt, history: history(turn))
      author = answer[:engine] == "ruby_llm" ? "#{answer[:model]} · RubyLLM" : "Demo guide"
      turn.with_lock do
        turn.update!(reply: answer[:reply].first(AssistantTurn::MAX_REPLY), author: author) unless turn.answered?
      end
      prune
    rescue ActiveRecord::RecordNotFound
      # The conversation was pruned while the model was thinking.
    end

    private

    def history(turn)
      AssistantTurn.where(assistant_chat_id: turn.assistant_chat_id).where.not(reply: "").where.not(id: turn.id)
        .where("created_at <= ?", turn.created_at).order(created_at: :desc, id: :desc).limit(HISTORY_TURNS)
        .pluck(:prompt, :reply).reverse.map { |pair| pair.map { |text| text.first(HISTORY_TEXT) } }
    end

    def prune
      AssistantChat.where.not(id: AssistantChat::EXAMPLES).order(created_at: :desc, id: :desc)
        .offset(KEPT_CHATS).each(&:destroy)
    end
  end
end
