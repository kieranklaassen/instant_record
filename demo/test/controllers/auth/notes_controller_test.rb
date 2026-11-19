require "test_helper"

module Auth
  class NotesControllerTest < ActionDispatch::IntegrationTest
    setup { AuthNote.seed_demo }

    def sign_in(id) = post(auth_session_url, params: { person: id }, as: :json)
    def titles = css_select(".auth-note h3").map(&:text)

    test "signed out, the page holds the public note and nothing else" do
      get auth_root_url

      assert_response :success
      assert_equal ["Welcome"], titles
      refute_includes response.body, "Payroll"
      refute_includes response.body, "gift list"
    end

    test "each person's page holds what they may see" do
      sign_in "ben"
      get auth_root_url
      assert_equal ["Ben's gift list", "Team lunch is Thursday", "Welcome"], titles.sort

      sign_in "ada"
      get auth_root_url
      assert_equal ["Ada's draft", "Payroll runs on the 28th", "Team lunch is Thursday", "Welcome"], titles.sort
    end

    test "a note is written as whoever is signed in, whatever the form says" do
      sign_in "ben"

      assert_difference -> { AuthNote.count }, 1 do
        post auth_notes_url, params: { note: { title: "Mine", body: "", audience: "owner", owner_id: "cleo" } }
      end
      assert_equal "ben", AuthNote.find_by!(title: "Mine").owner_id
    end

    test "signed out, nothing is written" do
      assert_no_difference -> { AuthNote.count } do
        post auth_notes_url, params: { note: { title: "Anon", body: "", audience: "everyone", owner_id: "ada" } }
      end
      assert_redirected_to auth_root_url
    end

    test "you delete your own notes and nobody else's" do
      sign_in "ben"

      assert_no_difference -> { AuthNote.count } do
        delete auth_note_url("auth-welcome")
        delete auth_note_url("auth-cleo")
      end
      assert_difference -> { AuthNote.count }, -1 do
        delete auth_note_url("auth-ben")
      end
    end

    test "the home page and the tabs lead here" do
      get root_url

      assert_select "a.demo-card-auth[href='/auth']"
      assert_select ".site-tabs a[href='/auth']", text: "Auth"
    end
  end
end
