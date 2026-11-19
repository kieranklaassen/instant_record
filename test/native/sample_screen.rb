# Every element a screen can hold, built from plain objects with no database.
# test/native_spinel_test.rb compiles this file with Spinel and runs it under
# CRuby, and the two must print the same bytes.
require "json"
require_relative "../../lib/instant_record/native/node"
require_relative "../../lib/instant_record/native/screen"

class Letter
  attr_reader :id, :from, :subject, :note

  # `note` may be nil, as a column of a record may be.
  def initialize(id, from, subject, note = nil)
    @id = id
    @from = from
    @subject = subject
    @note = note
  end
end

class LetterBox
  def initialize
    @letters = [
      Letter.new("a1", "Rae", "Night \"shift\"\n\tback\\slash café ☕"),
      Letter.new("b2", "Sam", "October invoice", "paid"),
      Letter.new("c3", "Jo", "")
    ]
  end

  def letters = @letters

  def archive(id)
    @letters = @letters.reject { |letter| letter.id == id }
  end
end

class LettersScreen < InstantRecord::Native::Screen
  def initialize(box, params)
    super(params)
    @box = box
  end

  def body
    navigation title: "Letters" do
      list refreshable: true do
        section "Open" do
          @box.letters.each do |letter|
            message = { "id" => letter.id, "note" => letter.note.to_s }
            row id: letter.id, link: "letter", params: place_of(letter.id) do
              stack "horizontal" do
                image "unread", tone: "accent"
                text letter.from, style: "headline", lines: 1
                spacer
                date "2026-11-19T06:00:00.000000Z", style: "caption", tone: "secondary"
              end
              text letter.subject, lines: 2
              swipe "Archive", action: "archive", args: message, role: "destructive", edge: "trailing", image: "archive"
            end
          end
        end
        section do
          text "#{@box.letters.size} letters", tone: "secondary"
        end
        more "older:letters", query: "type=Letter&before_id=" + @box.letters.last.id unless @box.letters.empty?
        swift "LetterCount" do
          number "count", @box.letters.size
          flag "empty", @box.letters.empty?
          time "checked", "2026-11-19T06:00:00.000000Z"
          props "senders" do
            @box.letters.each do |letter|
              record do
                prop "name", letter.from
                prop "subject", letter.subject
              end
            end
          end
        end
      end
      bottom do
        field "body", label: "Reply", value: param("box"), multiline: true
        field "subject"
        button "Send", action: "rename", image: "send"
      end
      toolbar do
        button "New", action: "compose", image: "square.and.pencil"
        button "Boxes", image: "person.crop.circle", position: "leading" do
          item "Here", link: "letters", params: place
          item "Inbox", replace: "letters", params: { "box" => "inbox" }, image: "inbox", selected: param("box") == "inbox"
          item "Sent \"mail\"", replace: "letters", params: { "box" => "sent" }, selected: param("box") == "sent"
          item "Empty", action: "empty", args: { "box" => param("box") }, role: "destructive"
        end
      end
    end
  end

  # Where this screen is, built from its own params as a real screen does.
  def place = { "box" => box, "odd" => param("odd") }
  def place_of(id) = { "box" => box, "odd" => param("odd"), "id" => id }

  # A param behind a method of its own, as a real screen reads one.
  def box = param("box")

  def perform(action, args, values)
    case action
    when "archive" then @box.archive(args.fetch("id", ""))
    when "rename" then @box.archive(values.fetch("id", ""))
    end
  end
end

# What a host sends: one JSON object, whose params may hold any characters.
input = JSON.parse("{\"screen\":\"letters\",\"params\":{\"box\":\"inbox\",\"odd\":\"a\\nb/c \\\"q\\\"\"},\"action\":\"archive\",\"args\":{\"id\":\"a1\"}}")
params = InstantRecord::Native::Screen.strings(input["params"])
args = InstantRecord::Native::Screen.strings(input["args"])
values = InstantRecord::Native::Screen.strings(input["values"])

box = LetterBox.new
puts LettersScreen.new(box, params).json
LettersScreen.new(box, params).perform(input["action"].to_s, args, values)
LettersScreen.new(box, params).perform("shred", { "id" => "b2" }, values)
puts LettersScreen.new(box, params).json
puts LettersScreen.new(LetterBox.new, params).param("box")
puts LettersScreen.new(LetterBox.new, params).param("odd").length
puts LettersScreen.new(LetterBox.new, params).param("missing").length
