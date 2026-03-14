# katran-build Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal wrapper repo that compiles katran's BPF programs with configurable flavors and publishes them as GitHub releases.

**Architecture:** `build.sh` downloads clang/LLVM 12, parses `flavors.conf`, and invokes katran's existing `Makefile-bpf` once per flavor. A GitHub Actions workflow automates weekly builds with `act` compatibility for local testing.

**Tech Stack:** Bash, Make (katran's existing Makefile-bpf), clang/LLVM 12, GitHub Actions, nektos/act

---

## File Map

| File | Responsibility |
|------|---------------|
| `.gitignore` | Exclude `_build/` directory |
| `flavors.conf` | Define build flavors and their `-D` flags |
| `build.sh` | Download toolchain, parse flavors, invoke make per flavor |
| `.actrc` | Default act flags for local workflow execution |
| `.github/workflows/build-and-release.yml` | CI/CD: weekly builds, submodule update, zip + release |

---

## Chunk 1: Config Files and Build Script

### Task 1: Create .gitignore and flavors.conf

**Files:**
- Create: `.gitignore`
- Create: `flavors.conf`

- [ ] **Step 1: Create `.gitignore`**

```
_build/
```

- [ ] **Step 2: Create `flavors.conf`**

```
# Flavor definitions: name:EXTRA_CFLAGS
# Add custom flavors by appending lines.
# Format: flavor-name:CFLAGS (everything after first colon is CFLAGS)
base:
decap-ipip:-DINLINE_DECAP_IPIP -DINLINE_DECAP_GENERIC
decap-gue:-DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC
full:-DINLINE_DECAP_IPIP -DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC -DGLOBAL_LRU_LOOKUP -DLPM_SRC_LOOKUP -DTCP_SERVER_ID_ROUTING
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore flavors.conf
git commit -m "feat: add .gitignore and flavors.conf"
```

### Task 2: Create build.sh

**Files:**
- Create: `build.sh`

**Reference files (read-only, in katran submodule):**
- `katran/build_bpf_modules_opensource.sh` — the upstream build orchestrator we're mirroring
- `katran/katran/lib/Makefile-bpf` — the actual BPF compilation Makefile

- [ ] **Step 1: Create `build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KATRAN_DIR="${SCRIPT_DIR}/katran"
BUILD_DIR="${SCRIPT_DIR}/_build"

# Overridable
CLANG_VERSION="${CLANG_VERSION:-12.0.0}"
FLAVORS_FILE="${FLAVORS_FILE:-${SCRIPT_DIR}/flavors.conf}"

CLANG_RELEASE="clang+llvm-${CLANG_VERSION}-x86_64-linux-gnu-ubuntu-20.04"
CLANG_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${CLANG_VERSION}/${CLANG_RELEASE}.tar.xz"
CLANG_PATH="${BUILD_DIR}/deps/clang/${CLANG_RELEASE}"

BPF_TARGETS=(
  bpf/balancer.bpf.o
  bpf/healthchecking.bpf.o
  bpf/healthchecking_ipip.o
  bpf/xdp_pktcntr.o
  bpf/xdp_root.o
)

# --- Step 1: Download clang/LLVM ---
download_clang() {
  if [ -d "${CLANG_PATH}" ]; then
    echo "[INFO] clang ${CLANG_VERSION} already cached at ${CLANG_PATH}"
    return
  fi
  echo "[INFO] Downloading clang ${CLANG_VERSION}..."
  mkdir -p "${BUILD_DIR}/deps/clang"
  wget -nv -O "${BUILD_DIR}/deps/clang/${CLANG_RELEASE}.tar.xz" "${CLANG_URL}"
  echo "[INFO] Extracting..."
  tar -xf "${BUILD_DIR}/deps/clang/${CLANG_RELEASE}.tar.xz" -C "${BUILD_DIR}/deps/clang/"
  rm -f "${BUILD_DIR}/deps/clang/${CLANG_RELEASE}.tar.xz"
  echo "[INFO] clang ${CLANG_VERSION} ready at ${CLANG_PATH}"
}

# --- Step 2: Check kernel headers ---
check_kernel_headers() {
  if [ ! -f /usr/include/linux/ip.h ]; then
    echo "[ERROR] Linux kernel headers not found at /usr/include/linux/ip.h"
    echo "[ERROR] Install with: sudo apt-get install -y linux-headers-generic linux-libc-dev"
    exit 1
  fi
}

# --- Step 3: Parse flavors.conf ---
parse_flavors() {
  if [ ! -f "${FLAVORS_FILE}" ]; then
    echo "[ERROR] Flavors file not found: ${FLAVORS_FILE}"
    exit 1
  fi

  local line_num=0
  while IFS= read -r line || [ -n "${line}" ]; do
    line_num=$((line_num + 1))
    # Skip empty lines and comments
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    # Must contain a colon
    if [[ "${line}" != *:* ]]; then
      echo "[ERROR] ${FLAVORS_FILE}:${line_num}: malformed line (missing colon): ${line}"
      exit 1
    fi
    local name="${line%%:*}"
    # Validate name
    if [[ -z "${name}" || ! "${name}" =~ ^[a-zA-Z0-9-]+$ ]]; then
      echo "[ERROR] ${FLAVORS_FILE}:${line_num}: invalid flavor name: '${name}'"
      exit 1
    fi
    FLAVOR_NAMES+=("${name}")
    FLAVOR_FLAGS+=("${line#*:}")
  done < "${FLAVORS_FILE}"

  if [ ${#FLAVOR_NAMES[@]} -eq 0 ]; then
    echo "[ERROR] No flavors defined in ${FLAVORS_FILE}"
    exit 1
  fi
}

# --- Step 4: Build one flavor ---
build_flavor() {
  local name="$1"
  local flags="$2"
  local flavor_dir="${BUILD_DIR}/bpfprog/${name}"

  echo "[BUILD] Flavor '${name}' with EXTRA_CFLAGS='${flags}'"

  # Clean and create build tree
  rm -rf "${flavor_dir}"
  mkdir -p "${flavor_dir}/include"
  mkdir -p "${flavor_dir}/katran/lib"

  # Copy Makefile
  cp "${KATRAN_DIR}/katran/lib/Makefile-bpf" "${flavor_dir}/Makefile"

  # Copy BPF sources (for #include "katran/lib/bpf/..." paths)
  cp -r "${KATRAN_DIR}/katran/lib/bpf" "${flavor_dir}/katran/lib/"

  # Copy linux_includes to two locations:
  # 1) katran/lib/linux_includes/ — for #include "katran/lib/linux_includes/..." paths
  cp -r "${KATRAN_DIR}/katran/lib/linux_includes" "${flavor_dir}/katran/lib/linux_includes"
  # 2) include/ — for Makefile -I$(obj)/include flag
  cp "${KATRAN_DIR}"/katran/lib/linux_includes/* "${flavor_dir}/include/"

  # Copy decap sources (creates bpf/ output dir, needed by decap flavors)
  cp -r "${KATRAN_DIR}/katran/decap/bpf" "${flavor_dir}/"

  # Build with explicit targets (avoids broken 'all' recipe body)
  (
    cd "${flavor_dir}" && \
    LD_LIBRARY_PATH="${CLANG_PATH}/lib" make \
      EXTRA_CFLAGS="${flags}" \
      LLC="${CLANG_PATH}/bin/llc" \
      CLANG="${CLANG_PATH}/bin/clang" \
      "${BPF_TARGETS[@]}"
  )

  # Collect outputs
  local output_dir="${BUILD_DIR}/output/${name}"
  mkdir -p "${output_dir}"
  cp "${flavor_dir}"/bpf/*.o "${output_dir}/"

  echo "[BUILD] Flavor '${name}' done -> ${output_dir}/"
}

# --- Main ---
main() {
  FLAVOR_NAMES=()
  FLAVOR_FLAGS=()

  echo "=== katran-build ==="
  download_clang
  check_kernel_headers
  parse_flavors

  # Clean previous output
  rm -rf "${BUILD_DIR}/output"

  for i in "${!FLAVOR_NAMES[@]}"; do
    build_flavor "${FLAVOR_NAMES[$i]}" "${FLAVOR_FLAGS[$i]}"
  done

  echo ""
  echo "=== Build Summary ==="
  for name in "${FLAVOR_NAMES[@]}"; do
    echo "  ${name}/:"
    ls -1 "${BUILD_DIR}/output/${name}/" | sed 's/^/    /'
  done
  echo ""
  echo "Output directory: ${BUILD_DIR}/output/"
}

main "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x build.sh
```

- [ ] **Step 3: Verify build.sh runs locally**

Run: `./build.sh`

Expected: Downloads clang 12 (first run, ~300MB), compiles all 5 BPF objects for each flavor in `flavors.conf`, prints summary. Check:

```bash
ls _build/output/base/
# Expected: balancer.bpf.o  healthchecking.bpf.o  healthchecking_ipip.o  xdp_pktcntr.o  xdp_root.o

ls _build/output/full/
# Expected: same 5 files
```

If clang download fails (network issues), retry. If compilation fails, check that `linux-headers-generic` and `linux-libc-dev` are installed.

- [ ] **Step 4: Commit**

```bash
git add build.sh
git commit -m "feat: add build.sh for BPF compilation with flavor support"
```

---

## Chunk 2: GitHub Actions Workflow and act Support

### Task 3: Create .actrc

**Files:**
- Create: `.actrc`

- [ ] **Step 1: Create `.actrc`**

```
-P ubuntu-22.04=catthehacker/ubuntu:act-22.04
--artifact-server-path /tmp/act-artifacts
```

- [ ] **Step 2: Commit**

```bash
git add .actrc
git commit -m "feat: add .actrc for local workflow execution with nektos/act"
```

### Task 4: Create GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build-and-release.yml`

- [ ] **Step 1: Create workflow directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Create `.github/workflows/build-and-release.yml`**

```yaml
name: Build and Release katran BPF

on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-22.04

    steps:
      - name: Checkout with submodules
        uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0  # Full history for tag comparison

      - name: Update katran submodule to latest main
        run: |
          git -C katran fetch origin main
          git -C katran checkout origin/main

      - name: Check if build is needed (scheduled only)
        id: skip_check
        if: github.event_name == 'schedule'
        run: |
          CURRENT_SHA=$(git -C katran rev-parse --short HEAD)
          LATEST_TAG=$(git tag --sort=-v:refname | head -1 || true)
          if [ -n "${LATEST_TAG}" ]; then
            # Extract SHA from tag format v{DATE}-{SHA}
            TAG_SHA="${LATEST_TAG##*-}"
            if [ "${TAG_SHA}" = "${CURRENT_SHA}" ]; then
              echo "skip=true" >> "$GITHUB_OUTPUT"
              echo "[INFO] katran SHA ${CURRENT_SHA} unchanged since ${LATEST_TAG}, skipping build"
            else
              echo "skip=false" >> "$GITHUB_OUTPUT"
              echo "[INFO] katran SHA changed: ${TAG_SHA} -> ${CURRENT_SHA}"
            fi
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
            echo "[INFO] No previous tags found, proceeding with first build"
          fi

      - name: Exit if no changes
        if: steps.skip_check.outputs.skip == 'true'
        run: |
          echo "No katran changes since last release. Exiting."
          exit 0

      - name: Install system dependencies
        if: steps.skip_check.outputs.skip != 'true'
        run: sudo apt-get update && sudo apt-get install -y linux-headers-generic linux-libc-dev zip

      - name: Build BPF programs
        if: steps.skip_check.outputs.skip != 'true'
        run: ./build.sh

      - name: Determine version string
        if: steps.skip_check.outputs.skip != 'true'
        id: version
        run: |
          DATE=$(date +%Y.%m.%d)
          SHA=$(git -C katran rev-parse --short HEAD)
          VERSION="${DATE}-${SHA}"
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "date=${DATE}" >> "$GITHUB_OUTPUT"
          echo "sha=${SHA}" >> "$GITHUB_OUTPUT"
          echo "[INFO] Version: ${VERSION}"

      - name: Create release zip
        if: steps.skip_check.outputs.skip != 'true'
        run: |
          cd _build/output
          zip -r "${GITHUB_WORKSPACE}/katran-bpf-${{ steps.version.outputs.version }}.zip" .
          # Also copy to _build/ for local/act fallback
          cp "${GITHUB_WORKSPACE}/katran-bpf-${{ steps.version.outputs.version }}.zip" "${GITHUB_WORKSPACE}/_build/"

      - name: Upload artifact
        if: steps.skip_check.outputs.skip != 'true'
        uses: actions/upload-artifact@v4
        with:
          name: katran-bpf-${{ steps.version.outputs.version }}
          path: katran-bpf-${{ steps.version.outputs.version }}.zip

      - name: Commit submodule update
        if: steps.skip_check.outputs.skip != 'true' && !env.ACT
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add katran
          if git diff --cached --quiet; then
            echo "[INFO] No submodule changes to commit"
          else
            git commit -m "chore: update katran submodule to ${{ steps.version.outputs.sha }}"
            git push || echo "[WARN] Push failed, submodule update will be picked up next run"
          fi

      - name: Create GitHub release
        if: steps.skip_check.outputs.skip != 'true' && !env.ACT
        uses: softprops/action-gh-release@v2
        with:
          tag_name: v${{ steps.version.outputs.version }}
          name: katran-bpf v${{ steps.version.outputs.version }}
          body: |
            Katran BPF programs compiled from katran commit `${{ steps.version.outputs.sha }}`.

            Built flavors (see `flavors.conf` for definitions):
            - base
            - decap-ipip
            - decap-gue
            - full
          files: katran-bpf-${{ steps.version.outputs.version }}.zip
```

- [ ] **Step 3: Validate workflow YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-and-release.yml'))" && echo "YAML OK"
```

If `pyyaml` not installed: `pip install pyyaml` or use `act` validation in the next step.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-and-release.yml
git commit -m "feat: add GitHub Actions workflow for weekly BPF builds and releases"
```

### Task 5: Test with act (optional, requires act installed)

- [ ] **Step 1: Verify act can parse the workflow**

```bash
act --list
```

Expected: Shows the `build` job from `build-and-release.yml`.

- [ ] **Step 2: Run workflow locally with act**

```bash
act workflow_dispatch
```

Expected: Full build runs inside container, produces zip in `/tmp/act-artifacts/`. The "Commit submodule update" and "Create GitHub release" steps are skipped (gated by `!env.ACT`).

Note: First run pulls the `catthehacker/ubuntu:act-22.04` Docker image (~1.2GB). Clang download inside the container adds ~300MB. This is a one-time cost.

- [ ] **Step 3: Commit any fixes if needed**

If `act` reveals issues (e.g., missing dependencies in the container image), fix and commit.
