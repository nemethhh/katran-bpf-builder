# katran-build: Minimal BPF Build Wrapper

## Problem

Building katran's BPF programs from source requires navigating Facebook's full build system (CMake, fbcode_builder, folly dependencies). Users who only want the compiled BPF objects — for deploying katran as a load balancer — must pull in a large dependency tree that is irrelevant to BPF compilation.

## Solution

A wrapper repository that:
1. Contains katran as a git submodule
2. Downloads the clang/LLVM 12 toolchain (matching katran's opensource build)
3. Compiles all 5 BPF programs using katran's existing `Makefile-bpf`
4. Supports configurable build flavors via a simple config file
5. Automates builds and releases via GitHub Actions

## Repository Structure

```
katran-build/
├── katran/                          # git submodule (existing)
├── flavors.conf                     # flavor definitions
├── build.sh                         # local build script
├── .actrc                           # default act flags
├── .github/
│   └── workflows/
│       └── build-and-release.yml    # CI/CD pipeline
└── docs/
```

## Components

### flavors.conf

Line-based configuration. Each line defines a build flavor as `name:EXTRA_CFLAGS`. Empty lines and `#` comments are ignored. Lines without a colon or with empty names are errors.

The flavor name must be alphanumeric plus hyphens (matching `[a-zA-Z0-9-]+`). Everything after the first colon is the EXTRA_CFLAGS value (may contain additional colons if needed, though unlikely).

```
# Flavor definitions: name:EXTRA_CFLAGS
base:
decap-ipip:-DINLINE_DECAP_IPIP -DINLINE_DECAP_GENERIC
decap-gue:-DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC
full:-DINLINE_DECAP_IPIP -DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC -DGLOBAL_LRU_LOOKUP -DLPM_SRC_LOOKUP -DTCP_SERVER_ID_ROUTING
```

Users add custom flavors by appending lines. Each flavor produces a separate directory of compiled BPF objects.

### build.sh

Entry point for both local and CI builds.

**Responsibilities:**

1. **Download clang/LLVM 12.0.0** from `https://github.com/llvm/llvm-project/releases/download/llvmorg-12.0.0/clang+llvm-12.0.0-x86_64-linux-gnu-ubuntu-20.04.tar.xz`. Cache in `_build/deps/clang/`. The extracted directory is `clang+llvm-12.0.0-x86_64-linux-gnu-ubuntu-20.04/`. Set `CLANG_PATH` to this extracted directory. Skip download if the directory already exists.

2. **Check kernel headers** — verify `/usr/include/linux/ip.h` exists; error with `apt-get install linux-headers-generic` instructions if missing.

3. **Parse `flavors.conf`** — skip empty lines and `#` comments, error on malformed lines.

4. **For each flavor**, set up the build tree mirroring `build_bpf_modules_opensource.sh`:
   - Create `_build/bpfprog/<flavor>/`
   - Copy `katran/katran/lib/Makefile-bpf` to `_build/bpfprog/<flavor>/Makefile`
   - Copy `katran/katran/lib/bpf/` to `_build/bpfprog/<flavor>/katran/lib/bpf/`
   - Copy `katran/katran/lib/linux_includes/` to `_build/bpfprog/<flavor>/katran/lib/linux_includes/` (for `#include "katran/lib/linux_includes/..."` paths)
   - Copy `katran/katran/lib/linux_includes/*` to `_build/bpfprog/<flavor>/include/` (for `-I$(obj)/include` Makefile flag)
   - Copy `katran/katran/decap/bpf/` to `_build/bpfprog/<flavor>/bpf/` (needed by decap flavors; harmless for base)
   - Invoke make with explicit targets to avoid the broken `all` recipe body:
     ```
     cd _build/bpfprog/<flavor> && \
     LD_LIBRARY_PATH="${CLANG_PATH}/lib" make \
       -f Makefile \
       EXTRA_CFLAGS="<flags>" \
       LLC="${CLANG_PATH}/bin/llc" \
       CLANG="${CLANG_PATH}/bin/clang" \
       bpf/balancer.bpf.o bpf/healthchecking.bpf.o bpf/healthchecking_ipip.o bpf/xdp_pktcntr.o bpf/xdp_root.o
     ```
   - Copy `_build/bpfprog/<flavor>/bpf/*.o` to `_build/output/<flavor>/` (stripping the `bpf/` prefix)

5. **Print summary** of built flavors and output paths.

**Note on Makefile `-I$(obj)/usr/include`**: This path is vestigial in katran's Makefile-bpf — `build_bpf_modules_opensource.sh` never populates it. It is harmless (clang ignores missing `-I` dirs with no error). We do not create it.

**Note on Red Hat/CentOS**: The upstream script has a Red Hat code path using system clang. This wrapper targets Ubuntu only; the Red Hat path is intentionally unsupported.

**Environment variables (overridable):**
- `CLANG_VERSION` — default `12.0.0`, allows future version bumps
- `FLAVORS_FILE` — default `flavors.conf`

**Exit codes:** Non-zero on any build failure (inherits from `set -e`).

### GitHub Actions Workflow

**File:** `.github/workflows/build-and-release.yml`

**Triggers:**
- `schedule`: weekly on Sunday (`cron: '0 0 * * 0'`)
- `workflow_dispatch`: manual trigger

**Runner:** `ubuntu-22.04`

**Permissions:** `contents: write` (needed to push submodule updates and create releases).

**Steps:**

1. Checkout repo with submodule (`submodules: recursive`)
2. Update katran submodule to latest `main`: `git -C katran fetch origin main && git -C katran checkout origin/main`
3. **Skip check** (scheduled runs only): compare current katran SHA against the SHA embedded in the latest release tag. If unchanged, exit the workflow successfully with no artifacts. On first run (no prior tags), proceed. Manual dispatch always proceeds.
   - Extract SHA from latest tag: `git tag --sort=-v:refname | head -1` then parse the suffix after the last `-`.
4. Install system dependencies: `sudo apt-get install -y linux-headers-generic`
5. Run `./build.sh`
6. Determine version string: `DATE=$(date +%Y.%m.%d)` and `SHA=$(git -C katran rev-parse --short HEAD)`
7. Create zip: `katran-bpf-${DATE}-${SHA}.zip` containing one directory per flavor from `_build/output/`
8. Commit updated submodule ref (if changed) and push. If push fails (e.g., concurrent update), log a warning but continue to release creation — the submodule update will be picked up next run.
9. Create GitHub release tagged `v${DATE}-${SHA}` with the zip as an asset.

### Local CI with act (nektos/act)

The workflow is designed to be runnable locally via [act](https://github.com/nektos/act) for testing and local builds without pushing to GitHub.

**`.actrc`** — default flags so `act` just works:
```
-P ubuntu-22.04=catthehacker/ubuntu:act-22.04
--artifact-server-path /tmp/act-artifacts
```

**Workflow compatibility considerations:**
- The workflow must avoid GitHub-only features that `act` cannot emulate, or gate them behind `if: !env.ACT`. Specifically:
  - **Step 2 (submodule update)**: works in act — git operations are local.
  - **Step 3 (skip check)**: works — reads local git tags.
  - **Step 8 (commit and push)**: skipped under `act` (`if: github.event_name != '' && !env.ACT`). Local builds don't push.
  - **Step 9 (create release)**: skipped under `act` (`if: github.event_name != '' && !env.ACT`). Local builds just produce the zip.
- The zip artifact is produced using `actions/upload-artifact`. Under `act`, this writes to `--artifact-server-path`. The workflow also copies the zip to `_build/` as a local fallback path.

**Usage:**
```bash
# Build all flavors locally using the workflow (requires act installed)
act workflow_dispatch

# Or just use build.sh directly for local builds
./build.sh
```

`act` is optional — `build.sh` is the primary local build path. `act` is for verifying the full workflow locally before pushing CI changes.

### Release Artifact

**Filename:** `katran-bpf-YYYY.MM.DD-<7char-sha>.zip`

**Structure:**
```
katran-bpf-2026.03.14-4065efa.zip
├── base/
│   ├── balancer.bpf.o
│   ├── healthchecking.bpf.o
│   ├── healthchecking_ipip.o
│   ├── xdp_pktcntr.o
│   └── xdp_root.o
├── decap-ipip/
│   └── (same 5 files)
├── decap-gue/
│   └── (same 5 files)
└── full/
    └── (same 5 files)
```

## BPF Programs Included

| File | Purpose |
|------|---------|
| `balancer.bpf.o` | Main L4 load balancer (XDP) |
| `healthchecking.bpf.o` | Health check packet forwarding |
| `healthchecking_ipip.o` | IPIP health check variant |
| `xdp_pktcntr.o` | Packet counter |
| `xdp_root.o` | Root XDP program dispatcher |

## Dependencies

**Build-time (handled by build.sh):**
- clang/LLVM 12.0.0 — downloaded from LLVM GitHub releases
- Linux kernel headers — checked, user prompted to install if missing
- `make`, `tar`, `wget` — assumed present

**CI (handled by workflow):**
- `ubuntu-22.04` runner
- `linux-headers-generic` apt package

**Runtime:** None. The output is standalone BPF object files.

## Architecture

x86_64 only. The clang toolchain download and BPF target are both x86_64-specific.

## Versioning Scheme

`YYYY.MM.DD-<katran-commit-short-sha>`

- Date = build date
- SHA = katran submodule commit (7 chars)
- Git tag = `v` prefix: `v2026.03.14-4065efa`
- Multiple builds on the same day with different katran SHAs produce distinct tags (the SHA disambiguates)

## What This Repo Does NOT Do

- Build katran's userspace C++ code (KatranLb, bpfadapter, gRPC server, etc.)
- Depend on folly, glog, gflags, or any C++ libraries
- Generate BPF skeletons (`.skel.h`) — just raw `.bpf.o` files
- Support architectures other than x86_64
- Support Red Hat/CentOS (Ubuntu only)
