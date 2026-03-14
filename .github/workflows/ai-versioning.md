# AI-Driven Semantic Versioning

This project uses [GitHub Models](https://docs.github.com/en/github-models) to automatically determine semantic version numbers based on upstream [katran](https://github.com/facebookincubator/katran) commit history.

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
│    (GitHub Models)       │  to GPT-4.1 via ai-inference
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

The workflow includes multiple fallback mechanisms:

1. **Regex validation** — the LLM response is parsed with a strict `v[0-9]+\.[0-9]+\.[0-9]+` regex. If the model returns anything unexpected, the workflow falls back to a simple patch bump.

2. **Manual override** — you can bypass the LLM entirely by providing a `version_override` input when triggering the workflow manually.

3. **Force build** — the `force_build` input lets you re-release even when the katran submodule hasn't changed.

## Configuration

### GitHub Models Access

No extra secrets are required. The workflow uses the built-in `GITHUB_TOKEN` with `models: read` permission to call [GitHub Models](https://docs.github.com/en/github-models). This is a free, built-in capability for GitHub repositories.

### Changing the Model

To use a different model, edit the `model:` field in the `Ask LLM for version bump` step:

```yaml
uses: actions/ai-inference@v1
with:
  model: openai/gpt-4.1          # ← change this
```

Available models can be browsed at [github.com/marketplace/models](https://github.com/marketplace/models).

### Customising the Prompt

The system prompt is inline in the workflow file. To change how the LLM interprets commits, edit the `system-prompt:` block in the `determine-version` job.

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
