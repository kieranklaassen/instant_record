require "test_helper"

module InstantRecord
  class MutationsControllerTest < ActionDispatch::IntegrationTest
    def post_mutations(*mutations)
      post "/instant_record/mutations", params: { mutations: mutations }, as: :json
      assert_response :success
      response.parsed_body["results"]
    end

    def create_mutation(record_id:, title: "Ship it", mutation_id: SecureRandom.uuid)
      {
        id: mutation_id,
        record_type: "Issue",
        record_id: record_id,
        operation: "create",
        base_version: 0,
        changes: { title: title, state: "open" }
      }
    end

    test "create mutation applies, bumps version, and appends a change row" do
      record_id = SecureRandom.uuid
      results = post_mutations(create_mutation(record_id: record_id))

      assert_equal "applied", results.first["status"]
      assert_equal 1, results.first["version"]

      issue = Issue.find(record_id)
      assert_equal "Ship it", issue.title
      assert_equal 1, issue.server_version

      change = InstantRecord::Change.last
      assert_equal "create", change.operation
      assert_equal record_id, change.record_id
      assert_equal "Ship it", change.attributes_payload["title"]
    end

    test "replaying the same mutation id returns original result without re-applying" do
      record_id = SecureRandom.uuid
      mutation = create_mutation(record_id: record_id)

      first = post_mutations(mutation)
      change_count = InstantRecord::Change.count
      replay = post_mutations(mutation)

      assert_equal first.first["status"], replay.first["status"]
      assert_equal change_count, InstantRecord::Change.count
      assert_equal 1, Issue.where(id: record_id).count
    end

    test "update mutation applies changes and bumps version" do
      record_id = SecureRandom.uuid
      post_mutations(create_mutation(record_id: record_id))

      results = post_mutations(
        id: SecureRandom.uuid, record_type: "Issue", record_id: record_id,
        operation: "update", base_version: 1,
        changes: { state: "done", updated_at: 1.minute.from_now.iso8601 }
      )

      assert_equal "applied", results.first["status"]
      assert_equal 2, results.first["version"]
      assert_equal "done", Issue.find(record_id).state
    end

    test "older concurrent update is skipped by last-write-wins" do
      record_id = SecureRandom.uuid
      post_mutations(create_mutation(record_id: record_id))
      issue = Issue.find(record_id)

      results = post_mutations(
        id: SecureRandom.uuid, record_type: "Issue", record_id: record_id,
        operation: "update", base_version: 1,
        changes: { title: "stale write", updated_at: (issue.updated_at - 1.hour).iso8601 }
      )

      assert_equal "applied", results.first["status"]
      assert results.first["skipped"]
      assert_equal "Ship it", issue.reload.title
    end

    test "validation-failing mutation is rejected with reason and no change row" do
      record_id = SecureRandom.uuid
      change_count = InstantRecord::Change.count

      results = post_mutations(create_mutation(record_id: record_id, title: "reject me"))

      assert_equal "rejected", results.first["status"]
      assert_match(/not allowed by the server/, results.first["reason"])
      assert_equal change_count, InstantRecord::Change.count
      assert_equal 0, Issue.where(id: record_id).count
    end

    test "unknown record type is rejected" do
      results = post_mutations(
        id: SecureRandom.uuid, record_type: "Secret", record_id: "x",
        operation: "create", base_version: 0, changes: { title: "nope" }
      )

      assert_equal "rejected", results.first["status"]
      assert_match(/unknown record type/, results.first["reason"])
    end

    test "batch with one bad mutation still applies the good ones" do
      good_id = SecureRandom.uuid
      results = post_mutations(
        create_mutation(record_id: good_id),
        create_mutation(record_id: SecureRandom.uuid, title: "reject me")
      )

      assert_equal %w[applied rejected], results.map { |r| r["status"] }
      assert Issue.exists?(good_id)
    end

    test "destroy mutation removes the record and logs a destroy change" do
      record_id = SecureRandom.uuid
      post_mutations(create_mutation(record_id: record_id))

      results = post_mutations(
        id: SecureRandom.uuid, record_type: "Issue", record_id: record_id,
        operation: "destroy", base_version: 1, changes: {}
      )

      assert_equal "applied", results.first["status"]
      refute Issue.exists?(record_id)
      assert_equal "destroy", InstantRecord::Change.last.operation
    end
  end
end
