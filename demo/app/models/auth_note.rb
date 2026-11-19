# A note with an audience. The two blocks below are the whole permission rule
# of the Auth demo, and they run on the server only: they decide what each
# browser is sent and which of its writes are taken. The browser's database
# never holds a note its person may not see.
class AuthNote < ApplicationRecord
  include InstantRecord::Syncable

  AUDIENCES = ["everyone", "members", "admins", "owner"].freeze

  validates :title, presence: true, length: { maximum: 120 }
  validates :body, length: { maximum: 2_000 }
  validates :audience, inclusion: { in: AUDIENCES }
  validates :owner_id, presence: true

  server_only do
    # Signed out: public notes. Signed in: those, the members' notes and your
    # own. An admin also sees the admins' notes. A note for its owner alone is
    # seen by its owner alone.
    syncable_to do |asker|
      person = asker&.person_id
      if person.nil?
        where(audience: "everyone")
      elsif AuthPerson.role_for(person) == "admin"
        where(audience: ["everyone", "members", "admins"]).or(where(owner_id: person))
      else
        where(audience: ["everyone", "members"]).or(where(owner_id: person))
      end
    end

    # You write your own notes and nobody else's. Signed out, you write nothing.
    writable_by do |asker|
      asker&.person_id ? where(owner_id: asker.person_id) : none
    end

    # The demo's starting notes, one or more for each audience. Idempotent.
    def self.seed_demo
      [
        ["auth-welcome", "ada", "everyone", "Welcome", "Anyone can read this, signed in or not. It is in every browser's database."],
        ["auth-lunch", "ben", "members", "Team lunch is Thursday", "Sent to anyone who is signed in, and to nobody who is not."],
        ["auth-payroll", "ada", "admins", "Payroll runs on the 28th", "Only admins are sent this. Sign in as Ben and it leaves your browser."],
        ["auth-ada", "ada", "owner", "Ada's draft", "Only Ada's browser ever holds this."],
        ["auth-ben", "ben", "owner", "Ben's gift list", "Only Ben's browser ever holds this. Not even an admin is sent it."],
        ["auth-cleo", "cleo", "owner", "Cleo's reminder", "Only Cleo's browser ever holds this."]
      ].each do |id, owner, audience, title, body|
        find_or_create_by!(id: id) do |note|
          note.assign_attributes(owner_id: owner, audience: audience, title: title, body: body)
        end
      end
    end
  end
end
