module Assistant
  class RepliesController < ActionController::API
    MAX_PROMPT = 8000
    MAX_TURNS = 6
    MAX_TURN_TEXT = 2000

    before_action do
      headers.merge!(InstantRecord::CORS_HEADERS)
      headers["Cache-Control"] = "no-store"
    end

    def preflight
      head :no_content
    end

    def create
      prompt = params[:prompt]
      history = params.fetch(:history, [])
      return head :unprocessable_entity unless text?(prompt, MAX_PROMPT) && prompt.present? && turns?(history)

      render json: Reply.call(prompt: prompt, history: history)
    end

    private

    def text?(value, limit)
      value.is_a?(String) && value.length <= limit
    end

    # Earlier turns of the conversation, oldest first, as [prompt, reply] pairs.
    def turns?(history)
      history.is_a?(Array) && history.size <= MAX_TURNS &&
        history.all? { |turn| turn.is_a?(Array) && turn.size == 2 && turn.all? { |text| text?(text, MAX_TURN_TEXT) } }
    end
  end
end
