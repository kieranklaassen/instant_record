#!/bin/sh
# Runs the Inbox's flows in the iPhone simulator against a server of its own.
#
#   native/ios/ui-test.sh                      every flow
#   native/ios/ui-test.sh testReplyToAConversation
#
# It recreates a database, seeds a fixed inbox (demo/db/seeds/native_ui.rb),
# starts the Rails demo with a token required, runs the tests, and stops the
# server. Nothing it changes outlives it, so it can be run again and again.
# Build the simulator libraries first: compiled/pipeline/build_native.py iphonesimulator.
#
#   DEVICE        the simulator, by name (iPhone 17)
#   PORT          where the server listens (3917)
#   UI_DATABASE   the database it may drop (postgres:///instant_record_native_ui)
#   SHOTS         a folder: each test's last screen is saved there as a PNG
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
device=${DEVICE:-iPhone 17}
port=${PORT:-3917}
work=$(mktemp -d)
signal="$work/signal"
log="$work/server.log"
server=""
export DATABASE_URL="${UI_DATABASE:-postgres:///instant_record_native_ui}" INBOX_REQUIRE_TOKEN=1 RAILS_ENV=development DISABLE_DATABASE_ENVIRONMENT_CHECK=1

start_server() {
  (cd "$repo/demo" && exec bundle exec falcon serve --bind "http://localhost:$port") >"$log" 2>&1 &
  server=$!
  i=0
  until curl -s -o /dev/null "http://localhost:$port/up"; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "The server did not start. See $log"; exit 1; }
    sleep 0.5
  done
}

stop_server() {
  [ -n "$server" ] || return 0
  pkill -P "$server" 2>/dev/null || true
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  server=""
}

finish() {
  stop_server
  xcrun simctl ui "$device" appearance light >/dev/null 2>&1 || true
  xcrun simctl ui "$device" content_size large >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap finish EXIT

# One xcodebuild run. While it runs, a test may ask for something only this
# script can do, by writing a line to the signal file and waiting for the
# file to go: stop or start the server, delete a message behind the app's
# back, or keep its last screen as a picture.
run_tests() {
  TEST_RUNNER_SIGNAL="$signal" TEST_RUNNER_SERVER="http://localhost:$port" TEST_RUNNER_TOKEN="$token" \
    xcodebuild test -project "$here/Inbox/Inbox.xcodeproj" -scheme Inbox -destination "platform=iOS Simulator,name=$device" \
    -derivedDataPath "${DERIVED:-$here/Inbox/build}" "$@" >"$work/xcodebuild.log" 2>&1 &
  tests=$!
  while kill -0 "$tests" 2>/dev/null; do
    if [ -f "$signal" ]; then
      asked=$(cat "$signal")
      case "$asked" in
        server-down) stop_server ;;
        server-up) [ -n "$server" ] || start_server ;;
        delete\ *) (cd "$repo/demo" && bin/rails runner "MailEntry.where(id: '${asked#delete }').delete_all" >/dev/null) ;;
        shot\ *) [ -z "${SHOTS:-}" ] || { mkdir -p "$SHOTS"; xcrun simctl io "$device" screenshot "$SHOTS/${asked#shot }.png" >/dev/null 2>&1; } ;;
      esac
      rm -f "$signal"
    fi
    sleep 0.2
  done
  wait "$tests" && status=0 || status=$?
  grep -E "^Test Case .*(passed|failed)|error:|Executed [0-9]+ tests" "$work/xcodebuild.log" | grep -v "^Test Suite" || true
  [ "$status" -eq 0 ] || { cp "$work/xcodebuild.log" "$repo/native/ios/ui-test-failure.log"; echo "Failed. Full log: native/ios/ui-test-failure.log"; exit "$status"; }
}

cd "$repo/demo"
bin/rails db:drop db:create db:schema:load >/dev/null
bin/rails runner db/seeds/native_ui.rb
token=$(bin/rails 'inbox:token[maya]')
xcrun simctl boot "$device" >/dev/null 2>&1 || true
start_server

if [ "$#" -gt 0 ]; then
  for name in "$@"; do set -- "$@" "-only-testing:InboxUITests/InboxUITests/$name"; shift; done
  run_tests "$@"
  exit 0
fi

run_tests -skip-testing:InboxUITests/InboxUITests/testTheMainControlsCanBeReachedHoweverTheyAreShown

# The same screen in the dark and at the largest text size.
xcrun simctl ui "$device" appearance dark
xcrun simctl ui "$device" content_size accessibility-extra-extra-extra-large
run_tests -only-testing:InboxUITests/InboxUITests/testTheMainControlsCanBeReachedHoweverTheyAreShown
echo "All simulator flows passed."
