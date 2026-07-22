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
  end
end
