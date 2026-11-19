module AuthHelper
  # The session and the sync endpoints are on the server. InstantRecord.server_url
  # builds the URL that reaches it from whichever runtime drew this page.
  def auth_session_endpoint
    InstantRecord.server_url(auth_session_path)
  end

  def auth_sign_out_endpoint
    InstantRecord.server_url(auth_session_sign_out_path)
  end

  def auth_bootstrap_endpoint
    InstantRecord.server_url("/instant_record/bootstrap")
  end

  def auth_mutations_endpoint
    InstantRecord.server_url("/instant_record/mutations")
  end

  def auth_audience_label(audience)
    case audience
    when "everyone" then "Everyone"
    when "members" then "Signed-in people"
    when "admins" then "Admins"
    else "Only its owner"
    end
  end
end
