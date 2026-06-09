#!/bin/bash
# lib/llm.sh — thin wrapper around any OpenAI-compatible Chat Completions endpoint.
#
# Usage: llm_call <purpose> <timeout_secs> <model> <prompt>
#   Returns the assistant message text on stdout.
#   Returns non-zero + error message on stderr on failure.
#
# Required env: LLM_API_BASE, LLM_API_KEY
# Optional env: LLM_LOG_FILE (append raw responses for debugging)

llm_call() {
  local purpose="$1" timeout="$2" model="$3" prompt="$4"
  local api_base="${LLM_API_BASE:-https://api.openai.com/v1}"
  local api_key="${LLM_API_KEY:-}"

  if [ -z "$api_key" ]; then
    echo "llm_call: LLM_API_KEY not set" >&2
    return 1
  fi

  # Escape the prompt for JSON embedding.
  local escaped
  escaped=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  if [ -z "$escaped" ]; then
    echo "llm_call: failed to JSON-encode prompt" >&2
    return 1
  fi

  local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":${escaped}}],\"temperature\":0.2}"

  local response
  response=$(timeout "$timeout" curl -s -f \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${api_base}/chat/completions" 2>/dev/null)

  local rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
    echo "llm_call[$purpose]: HTTP request failed (rc=$rc)" >&2
    return 1
  fi

  # Log raw response for debugging if requested.
  if [ -n "${LLM_LOG_FILE:-}" ]; then
    echo "=== $purpose $(date -Iseconds) ===" >> "$LLM_LOG_FILE"
    echo "$response" >> "$LLM_LOG_FILE"
  fi

  # Extract the assistant's reply.
  local text
  text=$(echo "$response" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])' \
    2>/dev/null)

  if [ -z "$text" ]; then
    echo "llm_call[$purpose]: empty or unparseable response" >&2
    echo "$response" >&2
    return 1
  fi

  echo "$text"
  return 0
}
