module Console
  # A REPL against whichever runtime served this page. Every other demo shows you
  # something it prepared; this one runs Ruby you typed, which is the only kind of
  # proof a skeptic can't call staged.
  #
  # ──────────────────────────────────────────────────────────────────────────
  #  DO NOT COPY THIS ENDPOINT INTO AN APPLICATION. It evaluates arbitrary Ruby.
  # ──────────────────────────────────────────────────────────────────────────
  #
  # It is defensible here, and only here, because of where "here" is. In the
  # browser runtime the VM, the database and the page all belong to the person
  # typing: they own the client, they can already open devtools and reach the same
  # objects, and nobody else's data is inside the tab. There is no privilege
  # boundary for an eval to cross, so handing them a prompt gives away nothing.
  #
  # On a server there IS a boundary, and an endpoint like this hands it over
  # completely — arbitrary code execution as the app user, against the real
  # database, on the real network. So the server does not have one:
  #
  #   * the evaluating `#create` is defined inside `browser_only`, and
  #     InstantRecord::RuntimeScoped only `class_eval`s that block in the browser
  #     runtime (see lib/instant_record/runtime_scoped.rb)
  #   * on the server the block never runs, so the method is never defined, so
  #     `Kernel#eval` is never reached from this app at all
  #   * the `server_only` `#create` answers instead, and all it does is explain
  #     itself in the pane where a visitor is already looking for the answer
  #
  # That is deliberately not a guard. A guard is a line of code that could be
  # bypassed, mis-ordered, or skipped by a `before_action` someone reorders later.
  # This is absence: in the server runtime the code that evaluates is not there.
  # It also means the boundary holds in every environment, including a deployed
  # demo server, without a `Rails.env` check to get wrong.
  class SessionsController < ApplicationController
    extend InstantRecord::RuntimeScoped

    # The one-click row. Each of these is a checkable claim about where the code
    # is running, not a scripted result: an adapter that names itself, the SQL
    # Rails is about to send, an association chain resolving against the local
    # database, and a write that commits before the network is consulted.
    SNIPPETS = [
      "ApplicationRecord.connection.class.name",
      "ApplicationRecord.connection.adapter_name",
      "Issue.all.to_sql",
      %(Issue.create!(title: "typed in the console")),
      "Issue.order(created_at: :desc).limit(3).map(&:title)",
      "Message.where(channel: Channel.channels.first).order(:created_at).last(3).map(&:body)",
      "InstantRecord.pending_count"
    ].freeze

    # An inspected value long enough to break the page tells you nothing more than
    # a truncated one does.
    OUTPUT_LIMIT = 2_000

    # The prompt's world: one binding, made once, so a local assigned on one line
    # is still in scope on the next — which is the difference between a REPL and a
    # form that evaluates expressions. `self` is a bare object rather than this
    # controller, so a typed line starts from roughly where `rails console` starts:
    # nothing in reach but the app's own constants. (Built here rather than taken
    # from TOPLEVEL_BINDING, whose presence depends on how the interpreter was
    # started — and the browser is the runtime this has to work in.)
    SESSION = Object.new.instance_eval { binding }

    def index
      @snippets = SNIPPETS
    end

    browser_only do
      skip_forgery_protection # no session secrets in the local runtime

      def create
        source = params[:code].to_s
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # The eval. Read the warning at the top of this file: in this runtime the
        # sandbox is the visitor's own tab.
        value = eval(source, SESSION, "(console)") # rubocop:disable Security/Eval

        result(source, value.inspect, elapsed(started))
      rescue StandardError, SyntaxError => e
        result(source, "#{e.class}: #{e.message}", elapsed(started), failed: true)
      end
    end

    server_only do
      def create
        result(params[:code].to_s, <<~EXPLANATION.squish, "refused", failed: true)
          Not evaluated — the Rails server answered this, and it has no eval
          action. Open the page through the service worker and the same
          controller runs in your browser's VM, where the blast radius is
          your own tab.
        EXPLANATION
      end
    end

    private

    def result(source, output, meta, failed: false)
      render partial: "result",
        locals: { source: source, output: output.truncate(OUTPUT_LIMIT), meta: meta, failed: failed }
    end

    def elapsed(started)
      "#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)} ms"
    end
  end
end
