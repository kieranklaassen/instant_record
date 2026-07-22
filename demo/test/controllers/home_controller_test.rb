require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "index introduces the library and links to every demo" do
    # /home, not /: the deployed boot splash in public/ shadows root on the
    # server (see config/routes.rb); the browser runtime serves root via Rack.
    get home_url

    assert_response :success
    assert_includes response.body, "InstantRecord"
    assert_includes response.body, todo_root_path
    assert_includes response.body, slack_root_path
  end
end
