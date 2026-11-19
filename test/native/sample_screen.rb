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
      Letter.new("c3", "Jo", "")
    ]
  end

  def letters = @letters

  def archive(id)
    @letters = @letters.reject { |letter| letter.id == id }
  end
end

class LettersScreen < InstantRecord::Native::Screen
  def initialize(box)
    super("inbox")
    @box = box
  end

  def body
    navigation title: "Letters" do
      list refreshable: true do
        section "Open" do
          @box.letters.each do |letter|
            row id: letter.id, link: "letter", arg: letter.id, action: "read" do
              stack "horizontal" do
                image "circle.fill", tone: "accent"
                text letter.from, style: "headline"
                date "2026-11-19T06:00:00.000000Z", style: "caption", tone: "secondary"
              end
              text letter.subject
              swipe "Archive", action: "archive", arg: letter.id, role: "destructive", edge: "trailing", image: "archivebox"
            end
          end
        end
        section do
          text "#{@box.letters.size} letters", tone: "secondary"
        end
        swift "LetterCount" do
          prop "count", @box.letters.size.to_s
          prop "empty", @box.letters.empty? ? "true" : ""
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
        button "New", action: "compose", image: "square.and.pencil"
        button "Boxes", image: "person.crop.circle", position: "leading" do
          item "Inbox", link: "letters", arg: "inbox", image: "tray", selected: arg == "inbox"
          item "Sent \"mail\"", link: "letters", arg: "sent", selected: arg == "sent"
          item "Empty", action: "empty", arg: arg, role: "destructive"
        end
      end
    end
  end

  def perform(action, arg)
    case action
    when "archive" then @box.archive(arg)
    end
  end
end

box = LetterBox.new
puts LettersScreen.new(box).json
LettersScreen.new(box).perform("archive", "a1")
LettersScreen.new(box).perform("shred", "b2")
puts LettersScreen.new(box).json
puts LettersScreen.new(LetterBox.new).arg
