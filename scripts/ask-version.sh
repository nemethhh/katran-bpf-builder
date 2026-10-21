#!/usr/bin/env bash
# Ask an OpenRouter model for the next semver based on katran/lib commits.
# Prints the new version tag (e.g. v1.4.5) on stdout; logs go to stderr.
# Exits non-zero if no model produced a valid next version.
set -euo pipefail

# Required
: "${OPENROUTER_KEY:?OPENROUTER_KEY is not set}"
: "${CURRENT_VERSION:?CURRENT_VERSION is not set}"
: "${COMMIT_LOG:?COMMIT_LOG is not set}"

# Overridable
OPENROUTER_MODELS="${OPENROUTER_MODELS:-nvidia/nemotron-3-ultra-550b-a55b:free,minimax/minimax-m3.1-flash:free,dots-studio/dots-3-note-preview:free,poolside/laguna-s-2.1:free}"   # comma-separated, tried in order
OPENROUTER_URL="${OPENROUTER_URL:-https://openrouter.ai/api/v1/chat/completions}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-20}"

log() { echo "$@" >&2; }

if ! [[ "$CURRENT_VERSION" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  log "[ERROR] CURRENT_VERSION '$CURRENT_VERSION' is not vMAJOR.MINOR.PATCH"
  exit 1
fi
MAJOR="${BASH_REMATCH[1]}" MINOR="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}"

# The only answers we accept: one of the three possible bumps
if [ "$CURRENT_VERSION" = "v0.0.0" ]; then
  ALLOWED=("v0.1.0")
else
  ALLOWED=("v$((MAJOR + 1)).0.0" "v${MAJOR}.$((MINOR + 1)).0" "v${MAJOR}.${MINOR}.$((PATCH + 1))")
fi

read -r -d '' SYSTEM_PROMPT <<'PROMPT_EOF' || true
You are a release versioning bot for an open-source project that
pre-compiles BPF programs from the upstream "katran" repository
(github.com/facebookincubator/katran).

You will receive:
  • CURRENT_VERSION — the latest semver tag (e.g. v1.2.3)
  • COMMIT_LOG     — one-line-per-commit log of upstream changes
                     in the katran/lib directory (BPF library source)
                     since the previous release

Your job:
  1. Analyse the commits for scope of change.
  2. Decide the semver bump:
       MAJOR — breaking / incompatible BPF map or API changes,
               removal of programs, kernel-version requirement changes.
       MINOR — new features, new BPF programs, new map types,
               significant refactors, new compile-time flags.
       PATCH — bug fixes, doc changes, CI tweaks, dependency bumps,
               cosmetic refactors, test-only changes.
  3. If CURRENT_VERSION is v0.0.0 (initial release) always return v0.1.0.
  4. Reply with ONLY the new version tag. No explanation, no markdown.
     Example valid reply:  v1.3.0
PROMPT_EOF

USER_PROMPT="CURRENT_VERSION: ${CURRENT_VERSION}

COMMIT_LOG:
${COMMIT_LOG}"

IFS=',' read -r -a MODELS <<<"${OPENROUTER_MODELS// /}"

# Ask one model; prints the version on success
ask_model() {
  local model="$1" request response error content next allowed
  request=$(jq -n \
    --arg model "$model" \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$USER_PROMPT" \
    '{
       model: $model,
       messages: [{role: "system", content: $system}, {role: "user", content: $user}],
       temperature: 0,
       max_tokens: 4000
     }')

  response=$(curl -sS -m 180 "$OPENROUTER_URL" \
    -H "Authorization: Bearer ${OPENROUTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$request") || { log "[WARN] ${model}: request failed"; return 1; }

  error=$(jq -r '.error.message // empty' <<<"$response" 2>/dev/null || echo "unparseable response")
  if [ -n "$error" ]; then
    log "[WARN] ${model}: ${error}"
    return 1
  fi

  content=$(jq -r '.choices[0].message.content // empty' <<<"$response")
  # Take the last version-looking token, so "v1.4.4 -> v1.4.5" resolves to v1.4.5
  next=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$content" | tail -n1 || true)
  for allowed in "${ALLOWED[@]}"; do
    if [ "$next" = "$allowed" ]; then
      log "[INFO] ${model} chose ${next}"
      echo "$next"
      return 0
    fi
  done
  log "[WARN] ${model}: invalid answer '${content}' (expected one of: ${ALLOWED[*]})"
  return 1
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  log "[INFO] Attempt ${attempt}/${MAX_ATTEMPTS}"
  for model in "${MODELS[@]}"; do
    [ -n "$model" ] || continue
    if ask_model "$model"; then
      exit 0
    fi
  done

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$RETRY_DELAY"
  fi
done

log "[ERROR] No valid version after ${MAX_ATTEMPTS} attempts"
exit 1
