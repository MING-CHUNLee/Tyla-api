# frozen_string_literal: true

# Measure a real GitHub Models 413 response to verify the body structure
# and confirm parse_max_input_tokens / extract_provider_error_message work.
#
# Run (PowerShell):
#   $env:LLM_DEBUG_LOG = "1"
#   $env:OPENAI_API_BASE = "https://models.inference.ai.azure.com/chat/completions"
#   $env:GITHUB_MODELS_TOKEN = "<your_pat>"
#   ruby scripts/measure_github_413.rb

$LOAD_PATH.unshift File.expand_path('../app', __dir__)

%w[infrastructure/llm/llm_error
   infrastructure/llm/llm_response
   infrastructure/llm/llm_debug_log
   infrastructure/llm/rate_limit_headers
   infrastructure/llm/openai_client].each { |f| require_relative "../app/#{f}" }

token = ENV['GITHUB_MODELS_TOKEN'] || ENV['GITHUB_TOKEN']
abort 'ERROR: set GITHUB_MODELS_TOKEN (or GITHUB_TOKEN) before running this script.' if token.nil? || token.strip.empty?

endpoint = ENV.fetch('OPENAI_API_BASE', 'https://models.inference.ai.azure.com/chat/completions')
log_path = 'log/llm_debug.log'

puts "endpoint → #{endpoint}"
puts "model    → #{ENV.fetch('LLM_MODEL', 'gpt-4o-mini')}"
puts "log      → #{log_path}"
puts

# ~10 000 tokens — well over the gpt-4o-mini 8 K per-request cap
oversized = ('lorem ipsum dolor sit amet consectetur adipiscing elit ' * 2_000).strip

client = Tyla::Infrastructure::OpenAiClient.new(api_key: token)

puts '==> Sending oversized prompt (expecting 413) …'
begin
  client.send_prompt(system_prompt: 'You are a helpful assistant.', user_message: oversized)
  puts '==> UNEXPECTED: request succeeded — try a larger oversized string or a smaller model cap.'
rescue Tyla::Infrastructure::LlmError::InputTooLarge => e
  puts '==> Got InputTooLarge — 413 parsed correctly!'
  puts "    max_input_tokens : #{e.max_input_tokens.inspect}"
  puts "    provider_message : #{e.provider_message.inspect}"
rescue Tyla::Infrastructure::LlmError::Upstream => e
  puts "==> Got Upstream (NOT InputTooLarge) — parser may need adjustment."
  puts "    message: #{e.message}"
rescue StandardError => e
  puts "==> Unexpected error: #{e.class}: #{e.message}"
end

puts
if File.exist?(log_path)
  raw    = File.read(log_path, encoding: 'utf-8')
  blocks = raw.split(/(?=={80,})/)
  last_413 = blocks.reverse.find { |b| b.include?('RESPONSE') && b.include?('413') }
  if last_413
    puts '=== raw 413 block from debug log ==='
    puts last_413.strip
  else
    puts '(no 413 block found in log — the request may not have reached the provider)'
  end
else
  puts "(#{log_path} not found — was LLM_DEBUG_LOG=1 set?)"
end
