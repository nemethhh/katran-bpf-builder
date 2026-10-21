# AI-Driven Semantic Versioning

This project uses free [OpenRouter](https://openrouter.ai) models to automatically determine semantic version numbers based on upstream [katran](https://github.com/facebookincubator/katran) commit history.

## How It Works

```
┌──────────────────────────┐
│  Scheduled / Manual Run  │
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│ 1. Detect Changes        │  Compare katran submodule SHA
│    (old tag → new HEAD)  │  in latest release vs upstream main
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│ 2. Gather Commit Log     │  git log old_sha..new_sha
│                          │  from facebookincubator/katran
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│ 3. AI Version Analysis   │  Feed commits + current version
│    (OpenRouter)          │  to free models via scripts/ask-version.sh
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│ 4. Build + Release       │  Tag with semver, publish zip
└──────────────────────────┘
```

## Versioning Rules

The LLM follows these semantic versioning guidelines:

| Bump  | Trigger examples |
|-------|-----------------|
| **MAJOR** | Breaking BPF map or API changes, removal of programs, kernel version requirement changes |
| **MINOR** | New features, new BPF programs, new map types, significant refactors, new compile-time flags |
| **PATCH** | Bug fixes, documentation, CI tweaks, dependency bumps, cosmetic changes, test-only changes |

## Safety Nets

1. **Model fallback and retries** — `scripts/ask-version.sh` asks each model in `OPENROUTER_MODELS` in order, and repeats the whole list up to 3 times with a 20s pause. Free models are often rate-limited or temporarily unavailable, so a single model is not enough.

2. **Answer validation** — a reply is only accepted if it is exactly one of the three possible next versions (major, minor or patch bump of the current tag). Anything else counts as a failed attempt and the next model is asked.

3. **Fail, then retry next run** — if no model gives a valid answer, the `determine-version` job fails and the build and release are skipped. No tag is created and the submodule bump is not pushed, so the next run compares against the same release and analyses the same commits again (plus any new ones).

4. **Manual override** — you can bypass the LLM entirely by providing a `version_override` input when triggering the workflow manually.

5. **Force build** — the `force_build` input lets you re-release even when the katran submodule hasn't changed.

## Configuration

### OpenRouter API key

The workflow reads the `OPENROUTER_KEY` repository secret. A free-tier key is enough: only `:free` models are used, and one run makes a handful of requests at most.

```bash
gh secret set OPENROUTER_KEY
```

### Changing the Models

Edit the `OPENROUTER_MODELS` env value at the top of the workflow (comma-separated, tried in order):

```yaml
env:
  OPENROUTER_MODELS: >-
    nvidia/nemotron-3-ultra-550b-a55b:free,
    minimax/minimax-m3.1-flash:free,
    ...
```

Free models come and go. List the current ones with:

```bash
curl -s https://openrouter.ai/api/v1/models | jq -r '.data[].id | select(endswith(":free"))'
```

Avoid the `openrouter/free` router: it may pick a very small model.

### Customising the Prompt

The system prompt lives in `scripts/ask-version.sh`. Edit the `SYSTEM_PROMPT` heredoc to change how the LLM interprets commits.

### Testing Locally

Put your key in an `openrouter_key` file in the repo root (it is git-ignored), then:

```bash
OPENROUTER_KEY=$(cat openrouter_key) \
CURRENT_VERSION=v1.4.4 \
COMMIT_LOG="$(git -C katran log --oneline --no-merges -10 -- katran/lib)" \
  ./scripts/ask-version.sh
```

## Migration from Date-Based Tags

The previous versioning scheme used `vYYYY.MM.DD-<sha>` tags. The workflow handles this transparently:

- It searches for semver tags (`v*.*.*`) first.
- If none exist (first run after migration), it starts from `v0.0.0` and the LLM will return `v0.1.0` as the initial release.
- Legacy date-based tags are left in place and not deleted.

## Manual Trigger Examples

```bash
# Normal run — AI picks the version
gh workflow run build-and-release.yml

# Force a specific version
gh workflow run build-and-release.yml -f version_override=v2.0.0

# Force rebuild even if katran hasn't changed
gh workflow run build-and-release.yml -f force_build=true
```
