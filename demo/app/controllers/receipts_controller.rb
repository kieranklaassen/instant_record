# What this runtime cost on this device — measured here, not quoted from a
# README. (A hardcoded bundle size in that README drifted 20MB from reality
# before this page existed; a number the page measures at runtime cannot.)
#
# Ordinary Rails, twice over: these actions run in the browser on ruby.wasm +
# PGlite when the service worker serves the page, and on the server on CRuby +
# Postgres when it does not. Nothing here asks which. The page times the same
# probe both ways — locally, and again with the marker that sends one request to
# the real server — so "the network is never in the hot path" becomes two
# numbers the visitor produced side by side.
class ReceiptsController < ApplicationController
  extend InstantRecord::RuntimeScoped

  browser_only do
    skip_forgery_protection   # no session secrets in the local runtime
  end

  # The browser runtime asks the server for the same probe. Served from :3000
  # that is same-origin; served by the Vite dev server it is cross-origin, like
  # the gem's own sync endpoints.
  before_action :allow_cross_origin, only: :probe

  def index
    # The URL that reaches the authoritative server from either runtime.
    @server_probe_url = InstantRecord.server_url(receipts_probe_path)
  end

  # A read and a write, timed by whichever runtime serves this request.
  #
  # The write is real: an INSERT, plus the outbox mutation that a syncable model
  # records in the same transaction. It runs inside a transaction that rolls
  # back, because measuring what a write costs must not leave a row behind or
  # queue a mutation somebody has to sync. The COMMIT — and in the browser the
  # IndexedDB flush behind it — is therefore not in this number, and the page
  # says so rather than passing it off as the cost of a full write.
  #
  # A GET that persists nothing stays a GET.
  def probe
    rows = Issue.count
    query_ms = elapsed { Issue.order(created_at: :desc).limit(20).to_a }

    write_ms = elapsed do
      Issue.transaction do
        Issue.create!(title: "receipt probe")
        raise ActiveRecord::Rollback
      end
    end

    render json: { rows: rows, query_ms: query_ms, write_ms: write_ms }
  end

  private

  def elapsed
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started_at).round(1)
  end

  def allow_cross_origin
    headers.merge!(InstantRecord::CORS_HEADERS)
  end
end
