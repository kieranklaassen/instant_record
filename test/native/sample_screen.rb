# Every element a screen can hold, built from plain objects with no database.
# test/native_spinel_test.rb compiles this file with Spinel and runs it under
# CRuby, and the two must print the same bytes.
require_relative "../../lib/instant_record/native/node"
require_relative "../../lib/instant_record/native/screen"

class Letter
  attr_reader :id, :from, :subject

  def initialize(id, from, subject)
    @id = id
    @from = from
    @subject = subject
  end
end

class LetterBox
  def initialize
    @letters = [
      Letter.new("a1", "Rae", "Night \"shift\"\n\tback\\slash café ☕"),
      Letter.new("b2", "Sam", "October invoice"),
      Letter.new("c/3", "Jo", nil)
    ]
    @notes = []
  end

  def letters = @letters
  def notes = @notes

  def archive(id)
    @letters = @letters.reject { |letter| letter.id == id }
  end

  def note(words)
    @notes << words
  end
end

# What two screens share lives in a module, as it does in an app.
module Boxed
  def box_name = param("box")
  def here(id) = { "box" => box_name, "id" => id }
end

class LettersScreen < InstantRecord::Native::Screen
  include Boxed

  def initialize(box, params)
    super(params)
    @box = box
  end

  def body
    navigation title: "Letters" do
      list refreshable: true do
        section "Open" do
          @box.letters.each do |letter|
            row id: letter.id, link: "letter", with: here(letter.id) do
              stack "horizontal" do
                image "unread", tone: "accent"
                text letter.from, style: "headline"
                spacer
                date "2026-11-19T06:00:00.000000Z", style: "caption", tone: "secondary"
              end
              text letter.subject, lines: 2
              swipe "Archive", action: "archive", with: here(letter.id), role: "destructive", edge: "trailing", image: "archive"
            end
          end
        end
        section do
          text "#{@box.letters.size} letters", tone: "secondary"
        end
        swift "LetterCount" do
          number "count", @box.letters.size
          flag "empty", @box.letters.empty?
          prop "box", box_name
          prop "nothing", nil
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
      toolbar do
        button "New", action: "compose", image: "compose"
        button "Boxes", image: "person", position: "leading" do
          item "Inbox", link: "letters", with: { "box" => "inbox" }, image: "inbox", selected: box_name == "inbox"
          item "Sent \"mail\"", link: "letters", with: { "box" => "sent" }, selected: box_name == "sent"
          item "Empty", action: "empty", with: { "box" => box_name }, role: "destructive"
        end
      end
      bottom do
        field "note", placeholder: "Add a note"
        button "Save", action: "note", image: "send"
      end
    end
  end

  def perform(action, params)
    case action
    when "archive" then @box.archive(params["id"].to_s)
    when "note" then @box.note(params["note"].to_s)
    end
  end
end

box = LetterBox.new
inbox = { "box" => "inbox" }
puts LettersScreen.new(box, inbox).json
LettersScreen.new(box, inbox).perform("archive", { "box" => "inbox", "id" => "a1" })
LettersScreen.new(box, inbox).perform("shred", { "id" => "b2" })
LettersScreen.new(box, inbox).perform("note", { "note" => "line one\nline \"two\"" })
puts LettersScreen.new(box, inbox).json
puts LettersScreen.new(LetterBox.new, inbox).param("box")
puts LettersScreen.new(LetterBox.new, inbox).param("missing").length
puts box.notes.size
puts box.notes[0]
