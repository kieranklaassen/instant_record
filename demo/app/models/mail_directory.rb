# Public personas for the demo. A private app would derive the person from its session.
class MailDirectory
  def self.inboxes(member)
    case member
    when "maya" then ["support", "billing"]
    when "theo" then ["support"]
    when "jo" then ["billing"]
    else []
    end
  end

  # A token that says who is asking, for a client that sends one. It is not
  # what keeps mail private here: these personas are public, and a request
  # with no token is served unless the server was started with
  # INBOX_REQUIRE_TOKEN. An app with private data requires the token and
  # takes the member from it, never from the address.
  def self.token(member)
    verifier.generate(member, purpose: :inbox_sync)
  end

  # The member a token was made for, or nil when it is not one of ours.
  def self.member_for(token)
    verifier.verified(token.to_s, purpose: :inbox_sync)
  end

  def self.verifier = Rails.application.message_verifier(:inbox_sync)
end
