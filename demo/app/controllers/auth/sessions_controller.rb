module Auth
  # The session, which exists on the server and nowhere else. The browser
  # runtime has no cookie secret and cannot read a session; the page asks here.
  #
  # An API controller, like the sync endpoints: it is reached from pages the
  # local runtime drew, which hold no forgery token of this server's. In its
  # place, a change of session must arrive as JSON, which a cross-site form
  # cannot send, and the session cookie is SameSite=Lax.
  class SessionsController < ActionController::API
    before_action { response.headers["Cache-Control"] = "no-store" }
    before_action :require_json, only: [:create, :destroy]

    def show
      render json: session_payload
    end

    def create
      person = AuthPerson.known(params[:person].to_s)
      return head :unprocessable_entity unless person

      reset_session
      session[:auth_person_id] = person
      session[:auth_signed_in_at] = Time.current.iso8601
      render json: session_payload
    end

    def destroy
      reset_session
      render json: session_payload
    end

    private

    def require_json
      head :unsupported_media_type unless request.content_mime_type&.json?
    end

    def session_payload
      person = AuthPerson.known(session[:auth_person_id])
      {
        signed_in: !person.nil?,
        person: person && { id: person, name: AuthPerson.name_for(person), role: AuthPerson.role_for(person) },
        signed_in_at: person && session[:auth_signed_in_at],
        # Counts, never contents: how many notes exist, and how many of them
        # this session may be sent.
        notes_on_server: AuthNote.count,
        notes_for_you: InstantRecord::SyncScope.visible(AuthNote, InstantRecord::SyncScope.identity(request)).count
      }
    end
  end
end
