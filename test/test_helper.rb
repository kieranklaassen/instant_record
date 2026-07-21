require "minitest/autorun"
require "active_record"
require "instant_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
