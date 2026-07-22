class IssuesController < ApplicationController
  skip_forgery_protection if InstantRecord.browser?

  def index
    @issues = Issue.order(created_at: :desc)
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

  def issue_params
    params.require(:issue).permit(:title)
  end
end
