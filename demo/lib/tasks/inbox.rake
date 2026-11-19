# The Inbox demo is the one page with a build step: Vite writes its React
# bundle to app/assets/builds/inbox.js, which Propshaft then serves.
namespace :inbox do
  desc "Build the Inbox demo's React bundle"
  task :build do
    Dir.chdir(Rails.root) do
      system("npm", "install", "--no-audit", "--no-fund", exception: true) unless Dir.exist?("node_modules")
      system("npm", "run", "build", exception: true)
    end
  end
end

%w[assets:precompile test:prepare].each do |task|
  Rake::Task[task].enhance(["inbox:build"]) if Rake::Task.task_defined?(task)
end
