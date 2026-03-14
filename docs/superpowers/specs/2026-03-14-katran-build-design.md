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
├── .github/
│   └── workflows/
│       └── build-and-release.yml    # CI/CD pipeline
└── docs/
```

## Components

### flavors.conf

Line-based configuration. Each line defines a build flavor as `name:EXTRA_CFLAGS`. Empty lines and `#` comments are ignored.

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
1. Download clang/LLVM 12.0.0 x86_64 tarball from LLVM GitHub releases (skip if already cached in `_build/deps/clang/`)
2. Ensure Linux kernel headers are installed (check `/usr/include/linux/ip.h`, error with install instructions if missing)
3. Parse `flavors.conf`
4. For each flavor:
   - Create a clean build directory using katran's expected layout (mirroring `build_bpf_modules_opensource.sh`)
   - Copy katran BPF sources and headers into the build directory
   - Invoke `make` with katran's `Makefile-bpf`, passing `CLANG=`, `LLC=`, and `EXTRA_CFLAGS=`
   - Collect outputs to `_build/output/<flavor>/`
5. Print summary of built flavors

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

**Steps:**
1. Checkout repo with submodule (`submodules: recursive`)
2. Update katran submodule to latest `main`: `git -C katran fetch origin main && git -C katran checkout origin/main`
3. Install system dependencies: `sudo apt-get install -y linux-headers-generic`
4. Run `./build.sh`
5. Determine version string: `DATE=$(date +%Y.%m.%d)` and `SHA=$(git -C katran rev-parse --short HEAD)`
6. Create zip: `katran-bpf-${DATE}-${SHA}.zip` containing one directory per flavor
7. Commit updated submodule ref (if changed) and push
8. Create GitHub release tagged `v${DATE}-${SHA}` with the zip as an asset

**Skip logic:** If the katran submodule SHA hasn't changed since the last release tag, skip the build (for scheduled runs only — manual dispatch always builds).

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
- clang/LLVM 12.0.0 — downloaded automatically
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

## What This Repo Does NOT Do

- Build katran's userspace C++ code (KatranLb, bpfadapter, gRPC server, etc.)
- Depend on folly, glog, gflags, or any C++ libraries
- Generate BPF skeletons (`.skel.h`) — just raw `.bpf.o` files
- Support architectures other than x86_64
