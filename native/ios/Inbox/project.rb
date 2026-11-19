#!/usr/bin/env ruby
# Writes Inbox.xcodeproj. Run it after adding or removing a Swift file:
#   ruby native/ios/Inbox/project.rb
require_relative "../../../lib/instant_record/native/xcode_project"

InstantRecord::Native::XcodeProject.new(
  folder: __dir__, name: "Inbox", bundle_id: "dev.instantrecord.Inbox",
  package: "../InstantRecordNative", headers: "../../../compiled/pipeline/native", libraries: "../../../compiled/.build-native",
  # The Feedback library, from a checkout of EveryInc/swift-libraries beside this repo.
  packages: { "Feedback" => "../../../../swift-libraries/feedback" }
).write
