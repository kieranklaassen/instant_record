module InstantRecord
  # Class-level blocks that only exist in one runtime. Syncable models get
  # these automatically; any other class (controllers, jobs, POROs) opts in:
  #
  #   class IssuesController < ApplicationController
  #     extend InstantRecord::RuntimeScoped
  #
  #     server_only do
  #       before_action :authenticate_user!   # sessions exist only on the server
  #     end
  #   end
  module RuntimeScoped
    def server_only(&block)
      class_eval(&block) unless InstantRecord.browser?
    end

    def browser_only(&block)
      class_eval(&block) if InstantRecord.browser?
    end

    # The same blocks by the name that fits a phone: the compiled app is the
    # client there, and no browser is in sight.
    alias_method :client_only, :browser_only
  end
end
