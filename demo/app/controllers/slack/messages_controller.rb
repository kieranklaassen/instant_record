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

      message = nil
      if body.present?
        # Author is always the visitor — never trusted from the form.
        message = Message.create!(channel: channel, chat_user_id: ChatUser::VISITOR_ID,
          body: body, parent_message_id: parent_id)
      end

      if params[:fragment] && message
        @channel = channel
        if parent_id
          @thread_parent = Message.find(parent_id)
          @thread_replies = [message]
          return render partial: "slack/channels/thread_replies", layout: false
        else
          @messages = [message]
          @reply_counts = {}
          @has_more = true
          return render partial: "slack/channels/messages", layout: false
        end
      end

      # Replying in a thread returns to the thread: the panel is URL state.
      redirect_to slack_channel_path(channel, thread: parent_id)
    end
  end
end
