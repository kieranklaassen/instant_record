class HomeController < ApplicationController
  extend InstantRecord::RuntimeScoped

  browser_only do
    skip_forgery_protection   # no session secrets in the local runtime
  end

  def index
  end
end
