require "test_helper"

module InstantRecord
  # syncable_to and writable_by over HTTP, with the Auth demo's notes: what the
  # sync endpoints send and take, by the session behind the request.
  class AuthSyncTest < ActionDispatch::IntegrationTest
    setup do
      AuthNote.seed_demo
      InstantRecord::Change.delete_all
    end

    def sign_in(id) = post("/auth/session", params: { person: id }, as: :json)
    def sign_out = post("/auth/session/sign_out", params: {}, as: :json)

    def bootstrap
      get "/instant_record/bootstrap"
      response.parsed_body
    end

    def notes(body = bootstrap)
      body["records"].select { |record| record["type"] == "AuthNote" }.map { |record| record["id"] }.sort
    end

    def events(**params)
      get "/instant_record/events", params: { after: 0, window: 0 }.merge(params)
      response.body.scan(/^data: (.+)$/).map { |(line)| JSON.parse(line) }
    end

    def mutate(operation, id, identity: nil, **changes)
      body = { mutations: [{ id: SecureRandom.uuid, record_type: "AuthNote", record_id: id, operation: operation, changes: changes }] }
      body[:identity] = identity if identity
      post "/instant_record/mutations", params: body, as: :json
      response.parsed_body.dig("results", 0)
    end

    test "a signed-out bootstrap holds the public note, and no secret anywhere in it" do
      body = bootstrap

      assert_equal %w[auth-welcome], notes(body)
      assert_equal "no-store", response.headers["cache-control"]
      refute_includes response.body, "Payroll"
      refute_includes response.body, "gift list"
      assert body["identity"].present?
    end

    test "each person's bootstrap holds their notes, under a key of their own" do
      anonymous = bootstrap["identity"]
      sign_in "ben"
      ben = bootstrap
      sign_in "ada"
      ada = bootstrap

      assert_equal %w[auth-ben auth-lunch auth-welcome], notes(ben)
      assert_equal %w[auth-ada auth-lunch auth-payroll auth-welcome], notes(ada)
      assert_equal 3, [anonymous, ben["identity"], ada["identity"]].uniq.size
      refute_includes ada["identity"], "ada"
    end

    test "a change to a secret reaches its people as it is, and everyone else as nothing" do
      AuthNote.find("auth-payroll").update!(body: "Moved to the 30th")

      assert_equal [{ "type" => "AuthNote", "id" => "auth-payroll", "operation" => "destroy", "version" => 0, "attributes" => {} }], events
      sign_in "ben"
      assert_empty events.first["attributes"]
      sign_in "ada"
      assert_equal ["update", "Moved to the 30th"], [events.first["operation"], events.first.dig("attributes", "body")]
    end

    test "a browser that synced as someone else is told to start over, and sent nothing more" do
      sign_in "ada"
      adas_key = bootstrap["identity"]
      AuthNote.find("auth-ada").update!(body: "Ada only")
      sign_out

      get "/instant_record/events", params: { after: 0, window: 0, identity: adas_key }

      assert_match(/\Aevent: reset\n/, response.body)
      assert_equal 1, response.body.scan("data: ").size
      reset = JSON.parse(response.body[/^data: (.+)$/, 1])
      assert_equal "reset", reset["operation"]
      assert_equal ["AuthNote"], reset["types"], "the Assistant's chats follow the browser's token, which did not change"
      refute_includes response.body, "Ada only"
    end

    test "writes queued as someone else are refused, and writes to open models are not" do
      sign_in "ada"
      adas_key = bootstrap["identity"]
      sign_in "ben"

      result = mutate("create", "left-over", identity: adas_key, title: "Queued as Ada", audience: "everyone", owner_id: "ben")

      assert_equal %w[rejected identity\ changed], result.values_at("status", "reason")
      refute AuthNote.exists?("left-over")
    end

    test "you write your own notes and nobody else's" do
      sign_in "ben"

      assert_equal "applied", mutate("create", "bens-new", title: "Mine", audience: "owner", owner_id: "ben")["status"]
      assert_equal %w[rejected not\ permitted], mutate("create", "forged", title: "Forged", audience: "everyone", owner_id: "cleo").values_at("status", "reason")
      assert_equal %w[rejected not\ permitted], mutate("update", "auth-welcome", title: "Defaced").values_at("status", "reason")
      assert_equal "Welcome", AuthNote.find("auth-welcome").title
      refute AuthNote.exists?("forged")
    end

    test "a secret answers a stranger as a missing record does" do
      sign_in "ben"

      update = mutate("update", "auth-cleo", title: "Seen")
      assert_equal %w[rejected record\ not\ found], update.values_at("status", "reason")
      assert_nil update["server_attributes"]
      assert_equal "applied", mutate("destroy", "auth-cleo")["status"]
      assert AuthNote.exists?("auth-cleo")
      create = mutate("create", "auth-cleo", title: "Taken?", audience: "owner", owner_id: "ben")
      assert_equal %w[rejected not\ permitted], create.values_at("status", "reason")
      assert_nil create["server_attributes"]
    end

    test "signed out, nothing is written" do
      result = mutate("create", "anon", title: "Anon", audience: "everyone", owner_id: "ada")

      assert_equal %w[rejected not\ permitted], result.values_at("status", "reason")
      refute AuthNote.exists?("anon")
    end

    test "a write must arrive as JSON, which a cross-site form cannot send" do
      sign_in "ben"
      post "/instant_record/mutations", params: { mutations: [{ id: "f", record_type: "AuthNote", record_id: "auth-ben", operation: "destroy" }] }

      assert_response :unsupported_media_type
      assert AuthNote.exists?("auth-ben")
    end
  end
end
