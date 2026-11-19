module Auth
  class NotesController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    def index
      @auth_notes = notes_scope.order(created_at: :desc).to_a
      @pending_count = InstantRecord.browser? ? InstantRecord.pending_count : 0
    end

    def create
      note = AuthNote.new(note_params)
      note.owner_id = note_owner
      note.save
      redirect_to auth_root_path
    end

    def destroy
      note = deletable_scope.find_by(id: params[:id])
      note.destroy! if note
      redirect_to auth_root_path
    end

    private

    def note_params
      params.require(:note).permit(:title, :body, :audience)
    end

    # In the browser there is no session to ask. The local database holds only
    # what the server sent this person, so all of it may be shown, and any of
    # it may be written here: the write is queued, and the server decides. A
    # write it refuses is rolled back in front of you.
    def notes_scope
      AuthNote.all
    end

    def deletable_scope
      AuthNote.all
    end

    # The page fills this in from the session it asked the server about.
    def note_owner
      params.require(:note).permit(:owner_id)[:owner_id].to_s
    end

    # On the server the session says who is asking, and the same two relations
    # that scope the sync endpoints scope this page.
    server_only do
      def asker = InstantRecord::SyncScope.identity(request)
      def notes_scope = InstantRecord::SyncScope.visible(AuthNote, asker)
      def deletable_scope = InstantRecord::SyncScope.writable(AuthNote, asker)
      def note_owner = asker.person_id

      private :asker, :notes_scope, :deletable_scope, :note_owner
    end
  end
end
