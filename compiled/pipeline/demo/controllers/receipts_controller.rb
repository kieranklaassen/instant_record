class ReceiptsController < ApplicationController
  def index
    @server_probe_url = "/receipts/probe?instant_record_network=1"
  end

  def probe
    rows = Issue.count
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Issue.order(created_at: :desc).limit(20).to_a
    query_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Release.exec_sql("SAVEPOINT receipt_probe")
    begin
      Issue.create!(title: "receipt probe")
    ensure
      Release.exec_sql("ROLLBACK TO receipt_probe")
      Release.exec_sql("RELEASE receipt_probe")
    end
    write_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
    render json: { rows: rows, query_ms: query_ms, write_ms: write_ms }
  end
end
