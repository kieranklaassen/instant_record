module Instant
  # Plain::TodosController again, action for action. What differs is where it
  # runs: InstantRecord compiles it into the browser, where Issue reads and
  # writes a local SQLite and syncs with the server behind the page.
  class TodosController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection # no session secrets in the local runtime
    end

    def index
      @todos = Issue.order(created_at: :desc)
    end

    def create
      Issue.create!(issue_params)
      redirect_to instant_root_path
    end

    def update
      Issue.find(params[:id]).update!(state: params[:done] == "1" ? "done" : "open")
      redirect_to instant_root_path
    end

    def destroy
      Issue.find(params[:id]).destroy!
      redirect_to instant_root_path
    end

    private

    def issue_params
      params.require(:issue).permit(:title)
    end
  end
end
