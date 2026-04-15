#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--isa <isa>] [--variant <default|small|medium|large>] [--cores <1|2>] [--out-dir DIR] [--jobs N] [--coverage|--coverage-light|--no-coverage] [--clean]
  ./build.sh --help

Build a runnable Chipyard BOOM Verilator simulator and emit a stable wrapper artifact.

Options:
  --isa <isa>           ISA/build variant (default: rv64fd). May be specified multiple times.
                        Supported: rv64fd
  --variant <name>      BOOM micro-architecture preset. May be specified multiple times.
                        Supported:
                          default (1c -> small, 2c -> small)
                          small
                          medium
                          large
  --cores <1|2>         Core count tag used for output naming (default: 1)
  --out-dir DIR         Output directory for final wrapper artifacts (default: ./build_result)
                        You can also set CX_OUT_DIR or OUT_DIR.
  --jobs N              Parallelism passed to make (default: auto-detect)
  --coverage            Verilator full coverage (output suffix: _cov)
  --coverage-light      Verilator line/user coverage (output suffix: _cov_light)
  --no-coverage         Disable coverage (default)
  --clean               Remove prior artifacts for the requested outputs
  --help, -h            Show this help

Output artifacts:
  default variant: <out-dir>/boom_<isa>_<N>c[_cov|_cov_light]
  tagged variants: <out-dir>/boom_<isa>_<variant>_<N>c[_cov|_cov_light]

Notes:
  - The top-level artifact is a wrapper script.
  - The actual simulator binary is staged under <out-dir>/.boom_internal/.
  - The wrapper injects the Chipyard runtime flags expected by the BOOM harness.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="${ROOT_DIR}/sims/verilator"
TESTCHIP_DRAMSIM_DIR="${ROOT_DIR}/generators/testchipip/src/main/resources/dramsim2_ini"

ISAS=()
VARIANTS=()
CORES="1"
CLEAN=0
COV_MODE="none" # none|full|light
OUT_DIR_OPT=""
JOBS=""

die() { echo "ERROR: $*" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

default_jobs() {
  if command_exists nproc; then
    nproc
    return
  fi
  if command_exists getconf; then
    getconf _NPROCESSORS_ONLN
    return
  fi
  if command_exists sysctl; then
    sysctl -n hw.ncpu
    return
  fi
  echo 1
}

infer_riscv_root() {
  if [[ -n "${RISCV:-}" ]]; then
    return
  fi
  local gcc_path
  gcc_path="$(command -v riscv64-unknown-elf-gcc || true)"
  [[ -n "${gcc_path}" ]] || die "RISCV is unset and riscv64-unknown-elf-gcc is not in PATH"
  export RISCV
  RISCV="$(cd "$(dirname "${gcc_path}")/.." && pwd)"
}

ensure_compatible_java() {
  local java_bin=""
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    java_bin="${JAVA_HOME}/bin/java"
  else
    java_bin="$(command -v java || true)"
  fi
  [[ -n "${java_bin}" ]] || die "java not found in PATH"

  local version_line major
  version_line="$("${java_bin}" -version 2>&1 | head -n 1)"
  major="$(sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' <<<"${version_line}")"
  [[ -n "${major}" ]] || {
    echo "[warn] failed to parse java version from: ${version_line}" >&2
    return
  }

  if (( major <= 17 )); then
    return
  fi

  local candidate
  for candidate in \
    /usr/lib/jvm/java-17-openjdk-amd64 \
    /usr/lib/jvm/java-1.17.0-openjdk-amd64
  do
    if [[ -x "${candidate}/bin/java" ]]; then
      export JAVA_HOME="${candidate}"
      export PATH="${JAVA_HOME}/bin:${PATH}"
      echo "[info] Using JAVA_HOME=${JAVA_HOME} for Chipyard/SBT compatibility"
      return
    fi
  done

  die "detected Java ${major}, but Chipyard/SBT on this tree needs JDK 17 or older and no compatible JDK was found"
}

canonical_variant() {
  local cores="$1"
  case "${cores}" in
    1) echo "small" ;;
    2) echo "small" ;;
    *) die "unsupported core count for default variant: ${cores}" ;;
  esac
}

config_class_for_variant() {
  local cores="$1"
  local variant="$2"
  case "${cores}:${variant}" in
    1:small) echo "CXBoomSmallV3TraceConfig" ;;
    1:medium) echo "CXBoomMediumV3TraceConfig" ;;
    1:large) echo "CXBoomLargeV3TraceConfig" ;;
    2:small) echo "CXBoomDualSmallV3TraceConfig" ;;
    2:medium) echo "CXBoomDualMediumV3TraceConfig" ;;
    2:large) echo "CXBoomDualLargeV3TraceConfig" ;;
    *) die "unsupported BOOM variant '${variant}' for ${cores} core(s)" ;;
  esac
}

coverage_suffix() {
  case "${COV_MODE}" in
    none) echo "" ;;
    full) echo "_cov" ;;
    light) echo "_cov_light" ;;
    *) die "internal: unknown coverage mode '${COV_MODE}'" ;;
  esac
}

verilator_opt_flags() {
  local base="-O3 --x-assign fast --x-initial fast --output-split 10000 --output-split-cfuncs 100"
  case "${COV_MODE}" in
    none) echo "${base}" ;;
    full) echo "${base} --coverage" ;;
    light) echo "${base} --coverage-line --coverage-user --coverage-max-width 0" ;;
    *) die "internal: unknown coverage mode '${COV_MODE}'" ;;
  esac
}

artifact_name_for() {
  local isa="$1"
  local cores="$2"
  local variant="$3"
  local suffix
  suffix="$(coverage_suffix)"
  if [[ "${variant}" == "default" ]]; then
    echo "boom_${isa}_${cores}c${suffix}"
  else
    echo "boom_${isa}_${variant}_${cores}c${suffix}"
  fi
}

write_wrapper() {
  local wrapper_path="$1"
  local simulator_rel="$2"
  local dramsim_dir="$3"

  cat >"${wrapper_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
SIM_BIN="\${SCRIPT_DIR}/${simulator_rel}"
DRAMSIM_INI_DIR="${dramsim_dir}"
MAX_CYCLES="\${BOOM_MAX_CYCLES:-10000000}"

[[ -x "\${SIM_BIN}" ]] || {
  echo "BOOM simulator binary is missing: \${SIM_BIN}" >&2
  exit 1
}
[[ -d "\${DRAMSIM_INI_DIR}" ]] || {
  echo "BOOM DRAMSim ini dir is missing: \${DRAMSIM_INI_DIR}" >&2
  exit 1
}
[[ \$# -ge 1 ]] || {
  echo "expected at least one ELF argument" >&2
  exit 1
}

args=("\$@")
elf="\${args[\$((\${#args[@]} - 1))]}"
sim_args=()
if (( \${#args[@]} > 1 )); then
  sim_args=("\${args[@]:0:\$((\${#args[@]} - 1))}")
fi

exec "\${SIM_BIN}" \\
  +permissive \\
  +dramsim \\
  "+dramsim_ini_dir=\${DRAMSIM_INI_DIR}" \\
  "+max-cycles=\${MAX_CYCLES}" \\
  "\${sim_args[@]}" \\
  +permissive-off \\
  "\${elf}"
EOF
  chmod +x "${wrapper_path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --isa)
      [[ $# -ge 2 ]] || die "--isa requires a value"
      ISAS+=("${2,,}")
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || die "--variant requires a value"
      VARIANTS+=("${2,,}")
      shift 2
      ;;
    --cores)
      [[ $# -ge 2 ]] || die "--cores requires a value"
      CORES="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR_OPT="$2"
      shift 2
      ;;
    --out-dir=*)
      OUT_DIR_OPT="${1#*=}"
      shift
      ;;
    --jobs)
      [[ $# -ge 2 ]] || die "--jobs requires a value"
      JOBS="$2"
      shift 2
      ;;
    --coverage)
      COV_MODE="full"
      shift
      ;;
    --coverage-light)
      COV_MODE="light"
      shift
      ;;
    --no-coverage)
      COV_MODE="none"
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ ${#ISAS[@]} -eq 0 ]]; then
  ISAS=("rv64fd")
fi
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
  VARIANTS=("default")
fi

[[ "${CORES}" == "1" || "${CORES}" == "2" ]] || die "--cores must be 1 or 2"
[[ -n "${JOBS}" ]] || JOBS="$(default_jobs)"
[[ "${JOBS}" =~ ^[0-9]+$ ]] || die "--jobs must be an integer"

OUT_DIR_DEFAULT="${ROOT_DIR}/build_result"
OUT_DIR="${OUT_DIR_OPT:-${CX_OUT_DIR:-${OUT_DIR:-${OUT_DIR_DEFAULT}}}}"
INTERNAL_DIR="${OUT_DIR}/.boom_internal"

mkdir -p "${OUT_DIR}" "${INTERNAL_DIR}"
[[ -d "${TESTCHIP_DRAMSIM_DIR}" ]] || die "missing DRAMSim ini directory: ${TESTCHIP_DRAMSIM_DIR}"

infer_riscv_root
ensure_compatible_java

declare -A BUILT_CONFIGS=()

for isa in "${ISAS[@]}"; do
  [[ "${isa}" == "rv64fd" ]] || die "unsupported --isa '${isa}' (supported: rv64fd)"

  for requested_variant in "${VARIANTS[@]}"; do
    case "${requested_variant}" in
      default|small|medium|large) ;;
      *) die "unsupported --variant '${requested_variant}' (supported: default, small, medium, large)" ;;
    esac

    resolved_variant="${requested_variant}"
    if [[ "${resolved_variant}" == "default" ]]; then
      resolved_variant="$(canonical_variant "${CORES}")"
    fi

    config_class="$(config_class_for_variant "${CORES}" "${resolved_variant}")"
    artifact_name="$(artifact_name_for "${isa}" "${CORES}" "${requested_variant}")"
    artifact_path="${OUT_DIR}/${artifact_name}"
    internal_sim_dir="${INTERNAL_DIR}/${artifact_name}"
    internal_sim_path="${internal_sim_dir}/simulator"
    simulator_src="${SIM_DIR}/simulator-chipyard.harness-${config_class}"
    simulator_rel=".boom_internal/${artifact_name}/simulator"

    if (( CLEAN )); then
      rm -rf "${artifact_path}" "${internal_sim_dir}"
    fi

    if [[ -z "${BUILT_CONFIGS[${config_class}]:-}" ]]; then
      echo "[build] ${artifact_name} (config=${config_class})"
      (
        cd "${ROOT_DIR}"
        make -C "${SIM_DIR}" "CONFIG=${config_class}" clean-sim >/dev/null
        make -C "${SIM_DIR}" -j"${JOBS}" \
          "CONFIG=${config_class}" \
          "VERILATOR_OPT_FLAGS=$(verilator_opt_flags)"
      )
      [[ -x "${simulator_src}" ]] || die "simulator binary not found at ${simulator_src}"
      BUILT_CONFIGS["${config_class}"]=1
    else
      echo "[reuse] ${artifact_name} (config=${config_class})"
    fi

    mkdir -p "${internal_sim_dir}"
    cp -f "${simulator_src}" "${internal_sim_path}"
    chmod +x "${internal_sim_path}"
    write_wrapper "${artifact_path}" "${simulator_rel}" "${TESTCHIP_DRAMSIM_DIR}"
    echo "  -> ${artifact_path}"
  done
done
