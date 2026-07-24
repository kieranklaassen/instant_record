# DDL in the browser runtime, made possible.
#
# wasmify-rails' PGlite adapter inherits Rails' PostgreSQL statement pool, whose
# `dealloc` asks the raw connection whether it is still usable before sending a
# DEALLOCATE:
#
#   if (conn = ...) && conn.status == PG::CONNECTION_OK
#
# Neither piece exists on the wasm side — the interface has no `status`, and the
# pg stub defines transaction statuses but not connection ones. Nothing hits that
# path until the pool is cleared, and the pool is cleared by DDL, so every
# migration in the browser died with `undefined method 'status'`: the boot
# catch-up (see InstantRecord::LocalSchema) and the demo that ships a migration
# on demand both.
#
# The fix is to say what is true rather than to make the deallocation work.
# PGlite's `prepare` only records the SQL in a Ruby-side map; nothing is prepared
# on the database, so there is nothing to deallocate, and a raw connection that
# does not answer PG::CONNECTION_OK is exactly how the pool is told to skip it.
# That covers every route into `dealloc` — a cleared cache, a deleted statement,
# and the eviction once the pool passes its limit.
#
# This belongs upstream in wasmify-rails; it lives here so the runtime this gem
# ships can run a migration at all.
require "active_record/connection_adapters/pglite_adapter"

module PG
  CONNECTION_OK = 0 unless defined?(CONNECTION_OK)
  CONNECTION_BAD = 1 unless defined?(CONNECTION_BAD)
end

module ActiveRecord
  module ConnectionAdapters
    class PGliteAdapter
      class ExternalInterface
        def status = PG::CONNECTION_BAD
      end
    end
  end
end
