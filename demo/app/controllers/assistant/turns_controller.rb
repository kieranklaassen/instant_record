module Assistant
  # The whole Assistant page: a list of chats, one chat's turns, and the two
  # writes a turn takes. Runs unchanged on Rails and in the browser, where it
  # reads and writes local SQLite.
  class TurnsController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    # Chats are private to a visitor. On Rails a signed cookie says who is
    # asking, and every query below is scoped to them. The browser needs
    # neither: its database only ever holds what Rails chose to send it
    # (sync_scope on the models), and Rails stamps what it sends up.
    server_only do
      before_action { @visitor = (cookies.signed.permanent[:assistant_visitor] ||= SecureRandom.uuid) }
    end

    PAGE = 8
    MAX_DEPTH = 200

    def index
      load_chat(params[:chat].to_s)
      render partial: "live", layout: false if params[:fragment]
    end

    # A question. It commits here first, and the turn's engine says who answers:
    # Rails once the record reaches it, or the model in this browser.
    def create
      chat_id = params.dig(:turn, :assistant_chat_id).to_s
      prompt = params.dig(:turn, :prompt).to_s.strip
      engine = params.dig(:turn, :engine).to_s == "local" ? "local" : "server"
      if chat_id != "" && prompt != ""
        chat = chats.find_by(id: chat_id)
        chat = AssistantChat.create!(id: chat_id, title: prompt[0, 80], visitor_id: @visitor) if chat.nil?
        AssistantTurn.create!(assistant_chat_id: chat.id, prompt: prompt, engine: engine, visitor_id: @visitor)
      end
      respond_after_write(chat_id)
    end

    # The answer of the browser's own model, saved onto the turn it was asked for.
    def update
      turn = turns.find(params[:id])
      reply = params.dig(:turn, :reply).to_s.strip
      if turn.engine == "local" && reply != ""
        turn.update!(reply: reply[0, AssistantTurn::MAX_REPLY], author: AssistantTurn::LOCAL_AUTHOR)
      end
      respond_after_write(turn.assistant_chat_id)
    end

    private

    def respond_after_write(chat_id)
      if params[:fragment]
        load_chat(chat_id)
        render partial: "live", layout: false
      else
        redirect_to assistant_root_path(chat: chat_id)
      end
    end

    # The newest turns of one chat, oldest first, and whether earlier ones exist.
    def load_chat(id)
      id = AssistantChat::EXAMPLES[0] if id == ""
      @chat_id = id
      @chats = chats.order(created_at: :desc, id: :desc).limit(60).to_a
      @chat = chats.find_by(id: id)
      @depth = [[params[:depth].to_i, PAGE].max, MAX_DEPTH].min
      newest = turns.where(assistant_chat_id: id).order(created_at: :desc, id: :desc).limit(@depth + 1).to_a
      @older = newest.size > @depth
      @turns = newest[0, @depth].reverse
    end

    def chats
      return AssistantChat.all if InstantRecord.browser?
      AssistantChat.where("visitor_id IS NULL OR visitor_id = :visitor", visitor: @visitor)
    end

    def turns
      return AssistantTurn.all if InstantRecord.browser?
      AssistantTurn.where("visitor_id IS NULL OR visitor_id = :visitor", visitor: @visitor)
    end
  end
end
