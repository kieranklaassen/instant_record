# Run against a deployed Rails demo before marking a rollout healthy.
# An unsupported operation exercises the real JSON parser without writing mail.
require "json"
require "net/http"
require "securerandom"

url = URI.join(ARGV.fetch(0), "/instant_record/mutations")
id = SecureRandom.uuid
payload = { mutations: [{ id: id, record_type: "MailEntry", record_id: id,
  operation: "update", changes: { kind: "message", mailbox_id: "support", author: "maya" } }] }
response = Net::HTTP.post(
  url,
  JSON.generate(payload),
  "Content-Type" => "application/json",
  "X-Instant-Record-Partition" => "mailbox_id:support",
  "X-Instant-Record-Member" => "maya"
)
abort "Mail sync returned HTTP #{response.code}" unless response.code == "200"
result = JSON.parse(response.body).fetch("results").fetch(0)
abort "Missing validation response for the submitted mutation" unless result.values_at("mutation_id", "status") == [id, "rejected"]
puts "Mail sync parsed the request and returned the expected validation response."
