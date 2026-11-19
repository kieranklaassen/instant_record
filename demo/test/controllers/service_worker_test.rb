require "test_helper"

class ServiceWorkerTest < ActionDispatch::IntegrationTest
  test "the service worker is served as JavaScript at the path the page registers" do
    get "/service-worker.js"

    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_includes response.body, %q{addEventListener("fetch"}
  end

  test "the page registers the path the worker is served at" do
    script = Rails.root.join("app/javascript/application.js").read

    assert_includes script, %q{navigator.serviceWorker.register("/service-worker.js")}
  end
end
