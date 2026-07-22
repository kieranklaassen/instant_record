module Slack
  # Replies to a visitor message as a fake user. Runs on the server only
  # (enqueued by a server_only callback); the reply is change-logged like any
  # server write and streams to every browser over SSE.
  class FakeReplyJob < ApplicationJob
    queue_as :default

    RESPONSES = {
      "bot-ursula" => [
        "Noted. I have aligned it to the grid.",
        "That message is 4pt off the baseline, but the sentiment lands.",
        "Agreed, provided we keep the margins honest."
      ],
      "bot-max" => [
        "Strong point. Flush left, ragged right, no notes.",
        "I ran the numbers: 100% Helvetica.",
        "Counterpoint: have you considered more white space?"
      ],
      "bot-adrian" => [
        "Yes. But say it in one typeface next time.",
        "The message works. The kerning is another conversation.",
        "Objectively correct, like a well-set headline."
      ],
      "bot-heidi" => [
        "Love this. Red accent, black text, no decoration.",
        "Adding this to the style guide under 'things we allow'.",
        "Swag as we wack, as the founders intended."
      ]
    }.freeze

    FALLBACK = [
      "Acknowledged, in uppercase.",
      "This sparks joy, within the constraints of the system."
    ].freeze

    def perform(message_id)
      message = Message.find_by(id: message_id)
      return unless message # deleted before the job ran (e.g. demo reset)

      channel = message.channel
      responder = pick_responder(channel)
      return unless responder&.bot?

      Message.create!(channel: channel, chat_user: responder, body: reply_body(responder))
    end

    private

    def pick_responder(channel)
      return ChatUser.find_by(id: channel.dm_user_id) if channel.dm?

      ChatUser.bots.order("RANDOM()").first
    end

    def reply_body(responder)
      RESPONSES.fetch(responder.id, FALLBACK).sample
    end
  end
end
