require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  test "index renders the ledger scaffolding and points the probe at both runtimes" do
    get receipts_url

    assert_response :success
    assert_includes response.body, "What this cost on"
    assert_includes response.body, %(data-controller="measure")
    assert_includes response.body, %(data-measure-local-url-value="#{receipts_probe_path}")
    assert_includes response.body, "#{receipts_probe_path}?instant_record_network=1",
      "the server column needs a URL the service worker passes to the network"
  end

  test "probe reports a query and a write timed by the runtime that served it" do
    Issue.create!(title: "already here")

    get receipts_probe_url

    assert_response :success
    figures = response.parsed_body

    assert_equal 1, figures["rows"]
    assert_kind_of Float, figures["query_ms"]
    assert_kind_of Float, figures["write_ms"]
    assert_operator figures["query_ms"], :>=, 0
    assert_operator figures["write_ms"], :>=, 0
  end

  test "probe leaves nothing behind — measuring a write must not queue one" do
    before = [Issue.count, InstantRecord::Change.count]

    get receipts_probe_url
    get receipts_probe_url

    assert_response :success
    assert_equal before, [Issue.count, InstantRecord::Change.count],
      "the timed write rolls back, so no row and no change-log entry survive it"
  end

  test "probe answers cross-origin, like the sync endpoints it sits beside" do
    get receipts_probe_url

    assert_equal "*", response.headers["access-control-allow-origin"]
  end
end
