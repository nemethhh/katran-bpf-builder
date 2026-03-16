# katran-bpf-builder

Pre-compiled [katran](https://github.com/facebookincubator/katran) BPF programs with configurable build flavors, published as GitHub releases.

## Quick Start

Download the latest release zip from the [Releases](../../releases) page, or build locally:

```bash
git clone --recursive https://github.com/nemethhh/katran-bpf-builder.git
cd katran-bpf-builder
sudo apt-get install -y linux-headers-generic linux-libc-dev
./build.sh
```

Output goes to `_build/output/<flavor>/`:

```
_build/output/
  base/
    balancer.bpf.o
    healthchecking.bpf.o
    healthchecking_ipip.o
    xdp_pktcntr.o
    xdp_root.o
  decap-ipip/
    ...
  decap-gue/
    ...
  full/
    ...
```

## Flavors

Flavors are defined in `flavors.conf`. Each line is `name:EXTRA_CFLAGS`:

| Flavor | Compile Flags | Description |
|--------|--------------|-------------|
| `base` | *(none)* | Vanilla katran BPF programs |
| `decap-ipip` | `-DINLINE_DECAP_IPIP -DINLINE_DECAP_GENERIC` | IPIP decapsulation support |
| `decap-gue` | `-DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC` | GUE decapsulation support |
| `full` | `-DINLINE_DECAP_IPIP -DINLINE_DECAP_GUE -DINLINE_DECAP_GENERIC -DGLOBAL_LRU_LOOKUP -DLPM_SRC_LOOKUP -DTCP_SERVER_ID_ROUTING` | All features enabled |

To add a custom flavor, append a line to `flavors.conf`:

```
my-flavor:-DINLINE_DECAP_IPIP -DGLOBAL_LRU_LOOKUP
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLANG_VERSION` | `12.0.0` | clang/LLVM version to download |
| `FLAVORS_FILE` | `flavors.conf` | Path to flavor definitions file |

## CI/CD

A GitHub Actions workflow runs weekly (Sunday midnight UTC) and on manual dispatch. It:

1. Updates the katran submodule to latest `main`
2. Checks for changes in `katran/lib/` (BPF library source) since the last release
3. Skips the build if no library changes are detected
4. Determines the next semantic version (`vMAJOR.MINOR.PATCH`) using AI-assisted analysis of library commits via [GitHub Models](https://github.com/marketplace/models)
5. Builds all flavors via `build.sh`
6. Publishes a zip of all outputs as a GitHub release

Trigger a build manually from the Actions tab or with:

```bash
gh workflow run build-and-release.yml
```

## Local CI Testing with act

[nektos/act](https://github.com/nektos/act) is supported for local workflow testing. The `.actrc` file maps the runner to the appropriate Docker image.

```bash
gh act workflow_dispatch
```

## Requirements

- Linux (x86_64)
- `linux-headers-generic` and `linux-libc-dev` packages
- `wget`, `tar`, `make` (for building)
- clang/LLVM 12 (downloaded automatically by `build.sh`)

## License

katran is licensed under the [GNU General Public License v2.0](https://github.com/facebookincubator/katran/blob/main/LICENSE). This wrapper repo provides build tooling only.
