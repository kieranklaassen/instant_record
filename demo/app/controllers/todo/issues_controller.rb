module Todo
  class IssuesController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    server_only do
      # Real apps put authentication and per-user scoping here: sessions,
      # cookies, and secrets exist only on the server. The browser runtime
      # renders from local SQLite, which only ever holds data the server chose
      # to sync down — so scoping is enforced at the sync boundary, not here.
      #
      #   before_action :authenticate_user!
      #   def issues_scope = current_user.issues
      #
      # The demo has no users; a response header stands in as a visible marker
      # that this filter ran on the server runtime only.
      before_action { response.set_header("x-instant-record-runtime", "server") }
    end

    def index
      load_list
      render partial: "list", layout: false if params[:fragment]
    end

    def create
      Issue.create!(issue_params)
      respond_after_write
    end

    def update
      issue = Issue.find(params[:id])
      issue.update!(state: params[:done] == "1" ? "done" : "open")
      respond_after_write
    end

    def destroy
      Issue.find(params[:id]).destroy!
      respond_after_write
    end

    private

    def load_list
      @issues = issues_scope.order(created_at: :desc)
      @pending_count = InstantRecord.browser? ? InstantRecord.pending_count : 0
    end

    def respond_after_write
      if params[:fragment]
        load_list
        render partial: "list", layout: false
      else
        redirect_to todo_root_path
      end
    end

    # In the browser this is all local data (already scoped by the server at
    # sync time); on a real server this is where current_user scoping lives.
    def issues_scope
      Issue.all
    end

    def issue_params
      params.require(:issue).permit(:title)
    end
  end
end
