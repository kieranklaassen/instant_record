module Migrate
  class NotesController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    def index
      @notes = Note.order(created_at: :desc)
      @columns = Release.local_columns
      @pending_count = InstantRecord.pending_count
      @release_pending = Release.pending?
    end

    def create
      Note.create!(note_params)
      redirect_to migrate_root_path
    end

    private

    def note_params
      params.require(:note).permit(:title, :body)
    end
  end
end
