# The people of the Auth demo. A real app has a users table and its own sign-in
# (Devise, has_secure_password); the demo has three people and a list to pick
# from, so the session and everything after it can be watched without a
# password. Names and roles are public, and both runtimes read them here.
class AuthPerson
  IDS = ["ada", "ben", "cleo"].freeze

  # The id a session names, or nil when it names nobody the demo knows.
  def self.known(id)
    IDS.include?(id) ? id : nil
  end

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
end
