module Slack
  class ChannelsController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    server_only do
      before_action { response.set_header("x-instant-record-runtime", "server") }
    end

    def index
      # Land on #general (the first seeded channel) when it exists.
      first_channel = Channel.find_by(id: Slack::Seeds::CHANNELS.first[:id]) || Channel.channels.first
      if first_channel
        redirect_to slack_channel_path(first_channel)
      else
        render :empty
      end
    end

    def show
      @channels = Channel.channels
      @dms = Channel.dms
      @users = ChatUser.order(:name)
      @channel = Channel.find(params[:id])
      @messages = @channel.messages.includes(:chat_user).order(:created_at, :id)
      @pending_count = InstantRecord.browser? ? InstantRecord.pending_count : 0
    end
  end
end
