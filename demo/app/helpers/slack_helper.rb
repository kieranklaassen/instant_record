module SlackHelper
  # The reset must hit the real server — only the server's change log
  # propagates to other clients. InstantRecord.server_url builds the URL that
  # reaches it from whichever runtime is rendering this page, so nothing here
  # has to ask which one that is.
  def slack_reset_endpoint
    InstantRecord.server_url(slack_reset_path)
  end

  # Avatar tile text: two initials, uppercase.
  def slack_initials(user)
    (user&.name || "??").split.map { |w| w[0] }.join[0, 2].upcase
  end
end
