module Console
  class SessionsController < ApplicationController
    def index
      @query = params[:query].to_s
      @output = case @query
      when "recent_issues"
        Issue.order(created_at: :desc).limit(10).map(&:title).join("\n")
      when "channels"
        Channel.channels.map(&:name).join("\n")
      when "pending"
        InstantRecord.pending_count.to_s
      else
        Issue.count.to_s
      end
    end
  end
end
