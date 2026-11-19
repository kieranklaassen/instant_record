module Email
  # Builds an inbox's shell away from the request that noticed it was missing
  # or behind. That request is answered with what exists; the next one gets this.
  class ShellBuildJob < ApplicationJob
    queue_as :default

    def perform(inbox)
      mailbox = Mailbox.find_by(id: inbox)
      MailShell.build(mailbox) if mailbox
    end
  end
end
