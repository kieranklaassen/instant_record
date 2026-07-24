module Slack
  class MessagesController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    server_only do
      before_action { response.set_header("x-instant-record-runtime", "server") }
    end

    def create
      channel = Channel.find(params.dig(:message, :channel_id))
      body = params.dig(:message, :body).to_s.strip
      # Optional thread parent; the model validates it is a top-level message
      # of this channel, so a forged id gets a rejection, not a stray row.
      parent_id = params.dig(:message, :parent_message_id).presence

      if body.present?
        # Author is always the visitor — never trusted from the form.
        Message.create!(channel: channel, chat_user_id: ChatUser::VISITOR_ID,
          body: body, parent_message_id: parent_id)
      end

      # Replying in a thread returns to the thread: the panel is URL state.
      redirect_to slack_channel_path(channel, thread: parent_id)
    end
  end
end
