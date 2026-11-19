# A note to the people who make the app. Nothing here is drawn from Ruby: the
# form is the Feedback library's own SwiftUI view (EveryInc/swift-libraries),
# which the iPhone app registers under this name and which sends the note
# itself. Comes up as a sheet from the mailbox's View menu.
class FeedbackScreen < InstantRecord::Native::Screen
  def body
    navigation title: "Feedback" do
      swift "FeedbackForm" do
        prop "from", param("member")
        prop "inbox", param("inbox")
      end
    end
  end
end
