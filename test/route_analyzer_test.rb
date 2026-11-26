require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "tmpdir"

class RouteAnalyzerTest < ActiveSupport::TestCase
  Compiler = InstantRecord::Compiler

  test "an app without a routes file has no routes, and cannot be asked for an island" do
    Dir.mktmpdir do |root|
      result = Compiler::RouteAnalyzer.analyze(source_root: root)

      assert_equal false, result.has_local_first
      assert_nil result.island
      assert_nil result.local_routes_source
      assert_empty result.declared_islands
      assert_empty result.local_routes
      assert_empty result.server_routes

      error = assert_raises(Compiler::BuildError) do
        Compiler::RouteAnalyzer.analyze(source_root: root, island: :tasks)
      end
      assert_equal "Missing config/routes.rb in #{File.expand_path(root)}", error.message
    end
  end

  test "a syntax error names the file and the line" do
    error = assert_raises(Compiler::BuildError) { analyze("Rails.application.routes.draw do\n  get (\nend\n") }

    assert_match(%r{\ASyntax error parsing .*/config/routes\.rb: line \d+: }, error.message)
  end

  test "without local_first every route is local, duplicates and rails/ routes dropped" do
    result = analyze_draw(<<~RUBY)
      get "up" => "rails/health#show"
      get "a", to: "pages#a"
      get "a", to: "pages#again"
      mount Engine => "/engine"
      if Rails.env.development?
        get "hidden", to: "pages#hidden"
      end
    RUBY

    assert_equal false, result.has_local_first
    assert_nil result.local_routes_source
    assert_equal ["GET /a pages#a"], routes(result.local_routes)
    assert_empty result.server_routes
  end

  test "resources draw the plural actions in order and resource the singular ones" do
    assert_local_routes <<~RUBY, <<~ROUTES
      resources :posts, :tags, param: :slug, only: [:index, :show, :update]
      resource :profile
    RUBY
      GET /posts posts#index
      GET /posts/:slug posts#show
      PATCH /posts/:slug posts#update
      PUT /posts/:slug posts#update
      GET /tags tags#index
      GET /tags/:slug tags#show
      PATCH /tags/:slug tags#update
      PUT /tags/:slug tags#update
      GET /profile/new profiles#new
      POST /profile profiles#create
      GET /profile profiles#show
      GET /profile/edit profiles#edit
      PATCH /profile profiles#update
      PUT /profile profiles#update
      DELETE /profile profiles#destroy
    ROUTES

    assert_local_routes "resources :posts, except: :update", <<~ROUTES
      GET /posts posts#index
      GET /posts/new posts#new
      POST /posts posts#create
      GET /posts/:id posts#show
      GET /posts/:id/edit posts#edit
      DELETE /posts/:id posts#destroy
    ROUTES
  end

  test "an only or except option may name one action, and a singular resource never has an index" do
    assert_local_routes <<~RUBY, <<~ROUTES
      resources :posts, only: :index
      resource :profile, only: %i[index show]
      resource :account, except: %i[new create edit update]
      resource "\\xff", path: "raw", controller: "bytes", only: :show
    RUBY
      GET /posts posts#index
      GET /profile profiles#show
      GET /account accounts#show
      DELETE /account accounts#destroy
      GET /raw bytes#show
    ROUTES
  end

  test "nested resources, member, collection and on: use the parent's path and controller" do
    assert_local_routes <<~RUBY, <<~ROUTES
      resources :posts, only: [], module: :blog, path: "articles" do
        resources :comments, only: [:index]
        member { get :preview }
        collection { get :recent }
        post :publish, on: :member
        get :search, on: :collection
        get :nested
        scope controller: "other" do
          get :plain
          get :by_name, on: :member
          get :by_target, on: :member, to: "shown"
        end
      end
    RUBY
      GET /articles/:post_id/comments blog/comments#index
      GET /articles/:id/preview blog/posts#preview
      GET /articles/recent blog/posts#recent
      POST /articles/:id/publish blog/posts#publish
      GET /articles/search blog/posts#search
      GET /articles/:post_id/nested blog/posts#nested
      GET /articles/:post_id/plain blog/other#plain
      GET /articles/:id/by_name blog/posts#by_name
      GET /articles/:id/by_target blog/other#shown
    ROUTES
  end

  test "member, collection and on: outside a resource keep the surrounding path and controller" do
    assert_local_routes <<~RUBY, <<~ROUTES
      scope "area", controller: "areas" do
        member { get :one }
        collection { get :many }
        get :each, on: :member
      end
    RUBY
      GET /area/one areas#one
      GET /area/many areas#many
      GET /area/each areas#each
    ROUTES
  end

  test "namespace and scope add a path, a module and a controller" do
    assert_local_routes <<~RUBY, <<~ROUTES
      namespace :admin do
        root "home#index"
        resources :users, only: [:index]
        get "absolute", to: "/pages#show"
        get "already", to: "admin/pages#show"
      end
      namespace :quiet, path: nil, module: "loud", controller: "sounds" do
        get :hum
      end
      namespace :bare, path: "", module: "" do
        get "b", to: "pages#b"
      end
      scope "/en", module: "english", controller: "words" do
        get "say-hello"
      end
      scope "ignored", path: "kept" do
        get "k", to: "pages#k"
      end
      scope module: "only_module" do
        get "m", to: "pages#m"
      end
      constraints(id: /x/) { get "c", to: "pages#c" }
      defaults(format: :json) { get "d", to: "pages#d" }
    RUBY
      GET /admin admin/home#index
      GET /admin/users admin/users#index
      GET /admin/absolute pages#show
      GET /admin/already admin/pages#show
      GET /hum loud/sounds#hum
      GET /b pages#b
      GET /en/say-hello english/words#say_hello
      GET /kept/k pages#k
      GET /m only_module/pages#m
      GET /c pages#c
      GET /d pages#d
    ROUTES
  end

  test "a verb route finds its controller in the target, the options or the path" do
    assert_local_routes <<~RUBY, <<~ROUTES
      root to: "home#index"
      get "a" => "pages#a"
      get "both", "x" => "pages#x"
      get "old", to: redirect("/new")
      get "old/page", to: redirect("/x")
      get foo: "pages#foo"
      get({ "braced" => "pages#braced" })
      get "splat", **opts
      get "named", controller: "pages", action: "named_action"
      get "pages/inferred", controller: "pages"
      get "deep/path/show"
      get "lonely"
      get target => "pages#dynamic"
    RUBY
      GET / home#index
      GET /a pages#a
      GET /x pages#x
      GET /old #
      GET /old/page #
      GET /foo pages#foo
      GET /braced pages#braced
      GET /splat #
      GET /named pages#named_action
      GET /pages/inferred pages#inferred
      GET /deep/path/show deep/path#show
      GET /lonely #
    ROUTES
  end

  test "an inferred controller keeps the module, controller and parameter around it" do
    assert_local_routes <<~RUBY, <<~ROUTES
      namespace :admin do
        get "c", controller: "pages"
        get "deep/show"
      end
      scope(controller: "words") { get "d", action: "e" }
      get "/lead/show"
      resources(:posts, only: []) { get :a, on: :member, action: "act" }
      resources :posts, only: [], param: :slug do
        resources :comments, only: [:index]
        scope("inner") { get :plain }
      end
      namespace(:admin) { get "/lead/show" }
      resources(:posts, only: []) { get "/pub-x", on: :member }
      resources :posts, "only" => :index
      get "first" => "pages#first", "second" => "pages#second"
      scope("area") { resources :posts, path: nil, only: :index }
      get "lazy", to: "pages#lazy", x: { key => %I[\\xff] }
      namespace(:unmoduled, module: nil) { get "u", to: "pages#u" }
      scope("unpathed", path: nil) { get "p", to: "pages#p" }
    RUBY
      GET /admin/c admin/pages#c
      GET /admin/deep/show admin/deep#show
      GET /d words#e
      GET /lead/show lead#show
      GET /posts/:id/a posts#act
      GET /posts/:post_slug/comments comments#index
      GET /posts/:post_slug/inner/plain posts#plain
      GET /admin/lead/show admin/lead#show
      GET /posts/:id/pub-x posts#pub_x
      GET /posts posts#index
      GET /first pages#first
      GET /area posts#index
      GET /lazy pages#lazy
      GET /unmoduled/u pages#u
      GET /p pages#p
    ROUTES
  end

  test "match draws the verbs named by via" do
    assert_local_routes <<~RUBY, <<~ROUTES
      match "one", to: "pages#one", via: :delete
      match "two", to: "pages#two", via: [:get, :put]
      match "all", to: "pages#all", via: :all
      match "none" => "pages#none"
    RUBY
      DELETE /one pages#one
      GET /two pages#two
      PUT /two pages#two
      GET /all pages#all
      POST /all pages#all
      PATCH /all pages#all
      PUT /all pages#all
      DELETE /all pages#all
      OPTIONS /all pages#all
      GET /none pages#none
      POST /none pages#none
    ROUTES
  end

  test "choosing one island leaves the other islands' routes on the server" do
    source = <<~RUBY
      local_first(:tasks, server_routes: ["POST /export"]) { get "t", to: "tasks#index" }
      local_first(:mail, server_routes: ["POST /send"]) { get "m", to: "mail#index" }
      get "s", to: "site#index"
    RUBY

    all = analyze_draw(source)
    assert_equal %w[mail tasks], all.declared_islands
    assert_equal ["GET /t tasks#index", "GET /m mail#index"], routes(all.local_routes)
    assert_equal %w[tasks mail], all.local_routes.map { |route| route["island"] }
    assert_equal ["GET /s site#index", "POST /export #", "POST /send #"], routes(all.server_routes)

    one = analyze_draw(source, island: :tasks)
    assert_equal "tasks", one.island
    assert_equal ["GET /t tasks#index"], routes(one.local_routes)
    assert_equal ["GET /m mail#index", "GET /s site#index", "POST /export #"], routes(one.server_routes)
    assert_equal "Rails.application.routes.draw do\n  get \"t\", to: \"tasks#index\"\nend\n", one.local_routes_source

    error = assert_raises(Compiler::BuildError) { analyze_draw("get 's', to: 'site#index'", island: "x") }
    assert_equal 'Unknown local_first island "x" in config/routes.rb (declared islands: none declared).', error.message
  end

  test "an island nested in the chosen one stays on the server" do
    result = analyze_draw('local_first(:one) { local_first(:two) { get "other", to: "o#i" } }', island: :one)

    assert_empty result.local_routes
    assert_equal ["GET /other o#i"], routes(result.server_routes)
  end

  test "an unnamed local_first belongs to the island around it, and false names no island" do
    result = analyze_draw(<<~RUBY)
      local_first(:outer) { local_first { get "i", to: "a#i" } }
      local_first(false) { get "f", to: "a#f" }
    RUBY

    assert_equal %w[outer], result.declared_islands
    assert_equal ["outer", nil], result.local_routes.map { |route| route["island"] }
  end

  test "a routes file without a draw block is read as the block's body" do
    assert_equal ["GET /a pages#a"], routes(analyze('get "a", to: "pages#a"').local_routes)
  end

  test "the local routes source keeps the containers around local routes and drops the rest" do
    result = analyze_draw(<<~RUBY, drawn: { "shared" => "get \"shared\", to: \"pages#shared\"" })
      scope "/:locale",
            module: "site" do |mapper|
        get "server", to: "pages#server"
        local_first do
          resources :posts do
            member do
              get :preview
            end
          end
          namespace :admin do
            local_first { root "home#index" }
            get "kept", to: "pages#kept"
          end
          resources :tags, only: [:index]
          direct(:skipped) { "/" }
        end
      end
      namespace(:empty) { get "e", to: "pages#e" }
      resources :server_only
      local_first do
          resource :profile do

            get :card
          end
        constraints(id: /x/) { match "c", to: "pages#c", via: :get }
        scope("drawn") { resources(:drawers) { draw(:shared) } }
        resources(:empty) { }
      end
    RUBY

    assert_equal <<~RUBY, result.local_routes_source
      Rails.application.routes.draw do
        scope "/:locale",
            module: "site" do |mapper|
          resources :posts do
            member do
              get :preview
            end
          end
          namespace :admin do
            root "home#index"
            get "kept", to: "pages#kept"
          end
          resources :tags, only: [:index]
        end
        resource :profile do

          get :card
        end
        constraints(id: /x/) { match "c", to: "pages#c", via: :get }
        scope("drawn") {
          resources(:drawers) {
            get "shared", to: "pages#shared"
          }
        }
        resources(:empty) { }
      end
    RUBY
  end

  test "names only known at runtime and a local_first without a block draw nothing" do
    result = analyze_draw(<<~RUBY)
      local_first(:bare)
      local_first do
        draw(name)
        namespace(name) { get "x", to: "x#y" }
        get "kept", to: "pages#kept"
      end
    RUBY

    assert_equal %w[bare], result.declared_islands
    assert_equal ["GET /kept pages#kept"], routes(result.local_routes)
    assert_equal <<~RUBY, result.local_routes_source
      Rails.application.routes.draw do
        namespace(name) { get "x", to: "x#y" }
        get "kept", to: "pages#kept"
      end
    RUBY
  end

  test "draw reads another routes file in place" do
    result = analyze_draw("namespace(:admin) { draw(:shared) }", drawn: {
      "shared" => "local_first { draw('deep/leaf') }",
      "deep/leaf" => "get 'leaf', to: 'leaves#show'"
    })

    assert_equal ["GET /admin/leaf admin/leaves#show"], routes(result.local_routes)
    assert_equal <<~RUBY, result.local_routes_source
      Rails.application.routes.draw do
        namespace(:admin) {
          get 'leaf', to: 'leaves#show'
        }
      end
    RUBY
  end

  test "draw rejects missing files, names outside config/routes and cycles" do
    {
      "Route file config/routes/gone.rb referenced by draw(:gone) does not exist" => ["draw(:gone)", {}],
      'Invalid route draw name "../gone": escapes config/routes/' => ["draw('../gone')", {}],
      "Cyclic route draw detected for config/routes/a.rb" => ["draw(:a)", { "a" => "draw(:b)", "b" => "scope('x') { draw(:a) }" }]
    }.each do |message, (source, drawn)|
      error = assert_raises(Compiler::BuildError) { analyze_draw(source, drawn: drawn) }
      assert_equal message, error.message
    end
  end

  test "the same file may be drawn twice when neither draw is inside the other" do
    result = analyze_draw("scope('a') { draw(:x) }\nscope('b') { draw(:x) }", drawn: { "x" => "get 'x', to: 'xs#show'" })

    assert_equal ["GET /a/x xs#show", "GET /b/x xs#show"], routes(result.local_routes)
  end

  private

  def assert_local_routes(source, expected)
    result = analyze_draw("local_first do\n#{source}\nend")
    assert_equal expected.lines(chomp: true), routes(result.local_routes)
    assert_empty result.server_routes
  end

  def routes(list)
    list.map { |route| "#{route["method"]} #{route["path"]} #{route["controller"]}##{route["action"]}" }
  end

  def analyze_draw(source, **options)
    analyze("Rails.application.routes.draw do\n#{source}\nend\n", **options)
  end

  def analyze(source, island: nil, drawn: {})
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/routes.rb"), source)
      drawn.each do |name, content|
        path = File.join(root, "config/routes/#{name}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      Compiler::RouteAnalyzer.analyze(source_root: root, island: island)
    end
  end
end
