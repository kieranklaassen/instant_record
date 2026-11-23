module InstantRecord
  # Builds a prebuilt SQLite shell away from the request that noticed it was
  # missing or behind. That request falls back to bootstrap (or serves the
  # aging shell); the next cold start opens this file directly.
  class ShellBuildJob < ActiveJob::Base
    queue_as :default

    def perform(identity = nil, source: nil, arg: nil)
      if source
        Shell.build_source(source, arg)
      else
        Shell.build(identity: Shell.load_identity(identity))
      end
    end
  end
end
