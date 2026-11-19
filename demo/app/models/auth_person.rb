# The people of the Auth demo. A real app has a users table and its own sign-in
# (Devise, has_secure_password); the demo has three people and a list to pick
# from, so the session and everything after it can be watched without a
# password. Names and roles are public, and both runtimes read them here.
class AuthPerson
  IDS = ["ada", "ben", "cleo"].freeze

  def self.name_for(id)
    case id
    when "ada" then "Ada"
    when "ben" then "Ben"
    when "cleo" then "Cleo"
    else "Someone"
    end
  end

  def self.role_for(id)
    id == "ada" ? "admin" : "member"
  end

  # Who a session names, or nil when it names nobody.
  def self.find(id)
    IDS.include?(id) ? new(id) : nil
  end

  attr_reader :id

  def initialize(id)
    @id = id
  end

  def name = self.class.name_for(id)
  def role = self.class.role_for(id)
  def admin? = role == "admin"
end
