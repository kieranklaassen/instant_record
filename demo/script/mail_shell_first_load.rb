# First load of an inbox, measured two ways from one native Ruby client: the
# bootstrap (fetch JSON, apply each record with the gem's client, read the
# first page) and the shell snapshot (fetch the prebuilt SQLite file, open it,
# read the first page). It says nothing certain about the compiled runtime,
# where applying a record costs more than it does here.
#
#   cd demo && RAILS_ENV=test bin/rails runner 'box = Mailbox.open_demo("support"); MailShell.build(box); puts MailShell.fingerprint'
#   RAILS_ENV=test bin/rails server -p 3999
#   cd .. && bundle exec ruby demo/script/mail_shell_first_load.rb <fingerprint>
require "bundler/setup"
require "active_record"; require "instant_record"; require "net/http"; require "json"; require "sqlite3"; require "tmpdir"
require "active_support/core_ext/time"; Time.zone = "UTC"
BASE = URI("http://127.0.0.1:3999/email/sync/maya/support"); FP = ARGV[0]; RUNS = 30
InstantRecord.singleton_class.define_method(:browser?) { true }
class MailEntry < ActiveRecord::Base; include InstantRecord::Syncable; end
HTTP = Net::HTTP.start(BASE.host, BASE.port)
def get(path) = HTTP.get(BASE.path + path)
dir = Dir.mktmpdir
# An empty browser database: the shell's schema with nothing in it.
template = File.join(dir, "empty.sqlite3")
grant = JSON.parse(get("/shell?fingerprint=#{FP}").body)
File.binwrite(File.join(dir, "seed.sqlite3"), get(grant["path"]).body)
ddl = SQLite3::Database.new(File.join(dir, "seed.sqlite3")).execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'").flatten
SQLite3::Database.new(template).tap { |db| ddl.each { |sql| db.execute(sql) } }.close
first_page = -> { MailEntry.where(kind: "message").order(created_at: :desc, id: :desc).limit(50).to_a.size }
ms = ->(&work) { t = Process.clock_gettime(Process::CLOCK_MONOTONIC); work.call; (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000 }
med = ->(xs) { xs.sort[xs.size / 2].round(1) }
a = { net: [], apply: [], total: [] }; b = { net: [], open: [], tail: [], total: [] }; sizes = {}
(RUNS + 3).times do |i|
  db = File.join(dir, "a#{i}.sqlite3"); FileUtils.cp(template, db)
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db)
  # As the browser runs it: no journal file and no fsync.
  ActiveRecord::Base.connection.execute("PRAGMA journal_mode = MEMORY"); ActiveRecord::Base.connection.execute("PRAGMA synchronous = OFF")
  body = nil
  net = ms.call { body = get("/bootstrap").body }
  apply = ms.call do
    payload = JSON.parse(body)
    payload["records"].each { |record| InstantRecord::Client.send(:apply_change, record) }
    InstantRecord::Client.cursor = payload["cursor"]
    sizes[:rows] = payload["records"].size
    first_page.call
  end
  sizes[:bootstrap] = body.bytesize
  next if i < 3
  a[:net] << net; a[:apply] << apply; a[:total] << net + apply
end
(RUNS + 3).times do |i|
  db = File.join(dir, "b#{i}.sqlite3"); bytes = nil; cursor = nil
  net = ms.call { g = JSON.parse(get("/shell?fingerprint=#{FP}").body); bytes = get(g["path"]).body }
  open = ms.call do
    File.binwrite(db, bytes)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db)
    cursor = InstantRecord::Client.cursor
    raise "not bootstrapped" unless InstantRecord::Client.bootstrapped?
    first_page.call
  end
  tail = ms.call { raise "behind" unless get("/events?after=#{cursor}").body.empty? }
  sizes[:shell] = bytes.bytesize
  next if i < 3
  b[:net] << net; b[:open] << open; b[:tail] << tail; b[:total] << net + open
end
puts "rows=#{sizes[:rows]} bootstrap=#{sizes[:bootstrap]}B shell=#{sizes[:shell]}B runs=#{RUNS}"
puts "bootstrap  network #{med[a[:net]]}ms  parse+apply+first page #{med[a[:apply]]}ms  total #{med[a[:total]]}ms"
puts "shell      network #{med[b[:net]]}ms  open+first page #{med[b[:open]]}ms  total #{med[b[:total]]}ms  (tail after, not blocking: #{med[b[:tail]]}ms)"
