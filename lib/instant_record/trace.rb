require_relative "trace/schema_extractor"
require_relative "trace/redactor"
require_relative "trace/replayer"

module InstantRecord
  # Deterministic `.irtrace` flight-recorder utilities: schema extraction for
  # PII redaction, Ruby-side SQLite checkpoint redaction, and Node AppHost replay.
  module Trace
    FORMAT = "instant_record.trace".freeze
    VERSION = 1

    class Error < StandardError; end

    def self.replay(**options)
      Replayer.new(**options).run
    end

    def self.redact(trace, **options)
      Redactor.new(**options).redact_trace(trace)
    end
  end
end
