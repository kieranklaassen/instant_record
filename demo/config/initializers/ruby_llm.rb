# The Assistant demo asks a model through RubyLLM when one of these keys is set
# (see Assistant::Reply). With none, it answers from its scripted guide.
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  # A visitor is waiting on the reply; the guide answers if the model is slow.
  config.request_timeout = 20
  config.max_retries = 1
end
