require "test_helper"

module Auth
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    setup { AuthNote.seed_demo }

    test "nobody is signed in to begin with, and the session says how little that is sent" do
      get auth_session_url

      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal({ "signed_in" => false, "person" => nil, "signed_in_at" => nil, "notes_on_server" => 6, "notes_for_you" => 1 },
        response.parsed_body)
    end

    test "signing in names the person, and signing out forgets them" do
      post auth_session_url, params: { person: "ada" }, as: :json
      assert_equal({ "id" => "ada", "name" => "Ada", "role" => "admin" }, response.parsed_body["person"])
      assert_equal 4, response.parsed_body["notes_for_you"]

      get auth_session_url
      assert response.parsed_body["signed_in"]
      assert response.parsed_body["signed_in_at"].present?

      post auth_session_sign_out_url, params: {}, as: :json
      refute response.parsed_body["signed_in"]
      get auth_session_url
      assert_equal 1, response.parsed_body["notes_for_you"]
    end

    test "each person is sent a different number of notes" do
      counts = %w[ada ben cleo].to_h do |id|
        post auth_session_url, params: { person: id }, as: :json
        [id, response.parsed_body["notes_for_you"]]
      end

      assert_equal({ "ada" => 4, "ben" => 3, "cleo" => 3 }, counts)
    end

    test "someone the demo does not know is not signed in" do
      post auth_session_url, params: { person: "mallory" }, as: :json

      assert_response :unprocessable_entity
      get auth_session_url
      refute response.parsed_body["signed_in"]
    end

    test "a change of session must arrive as JSON, which a cross-site form cannot send" do
      post auth_session_url, params: { person: "ada" }
      assert_response :unsupported_media_type

      post auth_session_url, params: { person: "ada" }, as: :json
      post auth_session_sign_out_url
      assert_response :unsupported_media_type
      get auth_session_url
      assert response.parsed_body["signed_in"], "a form post must not sign anyone out"
    end
  end
end
