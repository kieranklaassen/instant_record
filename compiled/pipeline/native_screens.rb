# Print the screens of an app as "name ClassName" lines, one for each file in
# its app/screens, for make_native_entry.py to write out as a `case`.
#
#   ruby native_screens.rb <staged app>
#
# The rule that turns a file's name into its class is InstantRecord::Native's.
# It is asked here and written nowhere else.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "instant_record/native"

folder = File.join(ARGV.fetch(0), "app/screens")
names = Dir.exist?(folder) ? Dir.children(folder).select { |file| file.end_with?("_screen.rb") }.map { |file| file.delete_suffix("_screen.rb") }.sort : []
begin
  names.each { |name| puts "#{name} #{InstantRecord::Native.class_name(name)}" }
rescue ArgumentError => error
  abort error.message
end
