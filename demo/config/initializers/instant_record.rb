Rails.application.config.to_prepare do
  InstantRecord.sync(Issue)
end
