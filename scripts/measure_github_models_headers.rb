# frozen_string_literal: true

# One-shot header measurement against real GitHub Models.
# Plan: plans/2026-06-18-provider-rate-limit-passthrough.md  §11 checklist item C3
#
# Goal: capture the exact `*ratelimit*` (and `retry-after`) header names that
# GitHub Models returns so the `tripped_rate_limit_dimension` helper can be
# calibrated with real field names.
#
# Prerequisites:
#   GITHUB_TOKEN (or GITHUB_MODELS_TOKEN) — a GitHub PAT or GitHub Actions
#   GITHUB_MODELS_TOKEN env var grants access to models.inference.ai.azure.com.
#
# Run:
#   LLM_DEBUG_LOG=1 ruby scripts/measure_github_models_headers.rb
#
# Or to pick a specific log path:
#   LLM_DEBUG_LOG=log/github_headers.log ruby scripts/measure_github_models_headers.rb
#
# The script prints the RESPONSE block from the debug log (which contains
# `headers=…`) so you can see every rate-limit field name the provider returns.

%w[llm_error llm_response llm_debug_log rate_limit_headers openai_client].each do |f|
  require_relative "../app/infrastructure/llm/#{f}"
end

GITHUB_MODELS_ENDPOINT = 'https://models.inference.ai.azure.com/chat/completions'
GITHUB_MODELS_MODEL    = ENV.fetch('GITHUB_MODELS_MODEL', 'gpt-4o-mini')

token = ENV['GITHUB_MODELS_TOKEN'] || ENV['GITHUB_TOKEN']
if token.nil? || token.strip.empty?
  warn 'ERROR: set GITHUB_MODELS_TOKEN (or GITHUB_TOKEN) before running this script.'
  exit 1
end

unless Tyla::Infrastructure::LlmDebugLog.enabled?
  warn 'LLM_DEBUG_LOG is not set — run with LLM_DEBUG_LOG=1 to capture headers.'
  warn 'Proceeding anyway; header output will appear on stderr only.'
end

log_path = Tyla::Infrastructure::LlmDebugLog.path || 'log/llm_debug.log'
puts "LLM_DEBUG_LOG → #{log_path}"
puts "Endpoint      → #{GITHUB_MODELS_ENDPOINT}"
puts "Model         → #{GITHUB_MODELS_MODEL}"
puts

client = Tyla::Infrastructure::OpenAiClient.new(
  api_key:  token,
  model:    GITHUB_MODELS_MODEL,
  endpoint: GITHUB_MODELS_ENDPOINT
)

puts '==> Sending minimal test prompt to GitHub Models …'
response = client.send_prompt(
  system_prompt: 'You are a helpful assistant.',
  user_message:  'Reply with exactly one word: hello'
)
puts "==> Success. Reply: #{response.content.inspect}"
puts "==> rate_limit bag: #{response.rate_limit.inspect}"
puts

# ── Print the RESPONSE block from the debug log ───────────────────────────────
if File.exist?(log_path)
  log_text = File.read(log_path)
  # Find the last RESPONSE block (the one we just wrote)
  blocks   = log_text.split(/(?=={80})/)
  last_req = blocks.reverse.find { |b| b.include?('← RESPONSE') }
  if last_req
    puts '=== RESPONSE block from debug log (showing captured headers) ==='
    puts last_req.strip
    puts
    # Extract just the headers= line for a focused summary
    header_line = last_req.match(/headers=\{[^}]*\}/m)&.to_s
    if header_line
      puts '>>> rate-limit headers captured:'
      puts header_line
    else
      puts '>>> (no ratelimit headers found in this response — provider returned none)'
    end
  else
    puts '(no RESPONSE block found in log yet)'
  end
else
  puts "(debug log not written — LLM_DEBUG_LOG was not set or write failed)"
end
