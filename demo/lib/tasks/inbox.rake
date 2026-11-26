# The Inbox demo is the one page with a build step: Vite writes its React
# bundle to app/assets/builds/inbox.js, which Propshaft then serves.
namespace :inbox do
  desc "Build the Inbox demo's React bundle"
  task :build do
    Dir.chdir(Rails.root) do
      system("npm", "ci", "--no-audit", "--no-fund", exception: true) unless Dir.exist?("node_modules")
      system("npm", "run", "build", exception: true)
    end
  end

  desc "Print a sync token for a member of the demo inbox: bin/rails 'inbox:token[maya]'"
  task :token, [:member] => :environment do |_task, args|
    abort "Name a member, such as maya." if MailDirectory.inboxes(args[:member]).empty?
    puts MailDirectory.token(args[:member])
  end
end

%w[assets:precompile test:prepare].each do |task|
  Rake::Task[task].enhance(["inbox:build"]) if Rake::Task.task_defined?(task)
end
