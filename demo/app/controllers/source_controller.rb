# The source of whatever page you are looking at, read off disk by the runtime
# that just rendered it. In the browser that disk is the packed `app.wasm`
# bundle: `config/wasmify.yml` packs `app/`, `lib/`, `config/` and `db/` into the
# module, so the Rails app in your tab can open its own model files the same way
# it opens its own ERB templates.
#
# Nothing here is a snippet pasted into a partial, which is the whole point —
# documentation that is read from the file it documents cannot drift away from
# it. If a demo page grows an ugly branch, the drawer publishes the branch.
class SourceController < ApplicationController
  layout false # a fragment, fetched by the page it describes

  # Which model files back which demo, keyed on the demo's namespace. The
  # controller and the view are named by Rails' own conventions, so they need no
  # table here; which models a page rendered is not something a path can tell us.
  # A demo missing from this list still gets its controller and view.
  MODELS = {
    "todo" => %w[app/models/issue.rb],
    "slack" => %w[app/models/channel.rb app/models/chat_user.rb app/models/message.rb],
    "migrate" => %w[app/models/note.rb app/models/release.rb],
    "console" => %w[app/models/issue.rb]
  }.freeze

  # Both params land in a file path, so both are pinned to one shape: lowercase
  # letters, digits and underscores, single slashes between segments. A path
  # traversal needs a dot or a leading slash and neither can match, so no request
  # reaches a file outside the app tree — and everything that does match is
  # checked for existence before it is read.
  PATH = /\A[a-z0-9_]+(?:\/[a-z0-9_]+)*\z/

  def show
    page, view = params[:page].to_s, params[:view].to_s
    return head :bad_request unless PATH.match?(page) && PATH.match?(view)

    @files = [
      *MODELS.fetch(page.split("/").first, []),
      "app/controllers/#{page}_controller.rb",
      "app/views/#{page}/#{view}.html.erb"
    ].map { |path| read(path) }
  end

  private

  # A file that isn't in this bundle says so. `public/` is deliberately not
  # packed and a demo may not be written yet, so "missing" is a real answer
  # rather than an error.
  def read(path)
    full = Rails.root.join(path)
    return { path: path } unless File.file?(full)

    { path: path, lines: File.readlines(full, chomp: true) }
  end
end
