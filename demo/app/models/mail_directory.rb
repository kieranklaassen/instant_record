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
end
