# /compare: the four todo apps next to each other, each in its own frame, with
# its stopwatch's reading above it. Rails serves this page and the first three
# apps. The fourth is only itself in a compiled build, so COMPARE_INSTANT_URL
# says where that build's /instant is; without it the frame shows /instant as
# Rails serves it, which is the plain app under another name.
class CompareController < ApplicationController
  layout false

  Way = Struct.new(:key, :name, :how, :files, keyword_init: true)

  WAYS = [
    Way.new(key: "plain", name: "Plain Rails", how: "A form, a redirect, a new page.",
            files: %w[app/models/plain app/controllers/plain app/views/plain]),
    Way.new(key: "hotwire", name: "Turbo Streams", how: "The server sends the piece that changed.",
            files: %w[app/models/hotwire app/controllers/hotwire app/views/hotwire]),
    Way.new(key: "inertia", name: "Inertia, optimistic", how: "React draws a guess, then the server's answer.",
            files: %w[app/models/inertia app/controllers/inertia app/frontend/todos.jsx app/frontend/todos]),
    Way.new(key: "instant", name: "InstantRecord", how: "The plain app, running in the browser.",
            files: %w[app/models/issue.rb app/controllers/instant app/views/instant])
  ].freeze

  def index
    @ways = WAYS
    @sizes = WAYS.to_h { |way| [way.key, size_of(way)] }
    @instant_url = ENV["COMPARE_INSTANT_URL"].presence
  end

  # Empties the four lists, so the four start level. The fourth list's rows
  # are destroyed one by one: each is a change its browsers are sent.
  def reset
    [Plain::Todo, Hotwire::Todo, Inertia::Todo].each(&:delete_all)
    Issue.destroy_all
    head :no_content
  end

  private

  # Lines that say something: not blank, not a comment.
  def size_of(way)
    files = way.files.flat_map do |path|
      full = Rails.root.join(path)
      full.directory? ? full.glob("**/*").select(&:file?) : [full]
    end
    lines = files.sum { |file| file.readlines.count { |line| line.strip.present? && !line.strip.start_with?("#", "//") } }
    { files: files.size, lines: lines }
  end
end
