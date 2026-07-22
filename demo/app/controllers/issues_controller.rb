class IssuesController < ApplicationController
  extend InstantRecord::RuntimeScoped

  browser_only do
    skip_forgery_protection   # no session secrets in the local runtime
  end

  server_only do
    # Real apps put authentication and per-user scoping here: sessions,
    # cookies, and secrets exist only on the server. The browser runtime
    # renders from local PGlite, which only ever holds data the server chose
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
    @issues = issues_scope.order(created_at: :desc)
    @pending_count = InstantRecord.browser? ? InstantRecord.pending_count : 0
  end

  def create
    Issue.create!(issue_params)
    redirect_to root_path
  end

  def update
    issue = Issue.find(params[:id])
    issue.update!(state: issue.state == "done" ? "open" : "done")
    redirect_to root_path
  end

  def destroy
    Issue.find(params[:id]).destroy!
    redirect_to root_path
  end

  private

  # In the browser this is all local data (already scoped by the server at
  # sync time); on a real server this is where current_user scoping lives.
  def issues_scope
    Issue.all
  end

  def issue_params
    params.require(:issue).permit(:title)
  end
end
