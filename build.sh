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
