#!/usr/bin/env bash
# Build the firmware listed in build.yaml locally, in the same Docker image
# GitHub Actions uses. Firmware lands in $ZMK_WORKSPACE/firmware/<artifact>.uf2.
#
#   ./build-local.sh                         build every target in build.yaml
#   ./build-local.sh blecorne_left-home      build only the named artifact(s)
#   ./build-local.sh --update                re-fetch ZMK/Zephyr first (picks up new ZMK main)
#   ./build-local.sh --pristine              wipe build dirs and build from scratch
#
# The west workspace (ZMK, Zephyr, modules, build dirs) lives outside this repo,
# by default in ../zmk-workspace, so it can't clash with zephyr/module.yml here.
set -euo pipefail

image=zmkfirmware/zmk-dev-arm:stable

if [[ -z ${IN_ZMK_CONTAINER:-} ]]; then
  repo=$(cd "$(dirname "$0")" && pwd)
  workspace=${ZMK_WORKSPACE:-$(dirname "$repo")/zmk-workspace}
  # Pre-create the nested mount point so Docker doesn't create it as root.
  mkdir -p "$workspace/config"
  exec docker run --rm -t \
    --user "$(id -u):$(id -g)" \
    -e IN_ZMK_CONTAINER=1 -e HOME=/workspace/.home \
    -v "$workspace:/workspace" \
    -v "$repo:/repo:ro" \
    -v "$repo/config:/workspace/config:ro" \
    -w /workspace \
    "$image" bash /repo/build-local.sh "$@"
fi

# --- Everything below runs inside the container. ---

update=0 pristine=auto targets=()
for arg in "$@"; do
  case $arg in
    --update) update=1 ;;
    --pristine) pristine=always ;;
    *) targets+=("$arg") ;;
  esac
done

[[ -d .west ]] || west init -l config
if [[ ! -d zmk || $update == 1 ]]; then
  west update --fetch-opt=--filter=tree:0
fi
west zephyr-export >/dev/null

# Turn each build.yaml entry into a shell-quoted "name board shield snippet"
# line followed by its raw cmake-args, which CI also splices in unquoted.
mapfile -t builds < <(python3 - <<'PY'
import shlex, yaml
for b in yaml.safe_load(open("/repo/build.yaml"))["include"]:
    shield = b.get("shield", "")
    name = b.get("artifact-name") or "-".join(filter(None, [shield.replace(" ", "-"), b["board"], "zmk"]))
    print(" ".join(shlex.quote(v) for v in [name, b["board"], shield, b.get("snippet", "")]))
    print(b.get("cmake-args", ""))
PY
)

mkdir -p firmware
built=0
for ((i = 0; i < ${#builds[@]}; i += 2)); do
  eval "set -- ${builds[i]}"
  name=$1 board=$2 shield=$3 snippet=$4
  cmake_args=${builds[i + 1]}

  if (( ${#targets[@]} )) && [[ ! " ${targets[*]} " == *" $name "* ]]; then
    continue
  fi

  echo "==> $name"
  eval "west build -p $pristine -s zmk/app -d build/$name -b $board \
    ${snippet:+-S $snippet} -- \
    -DZMK_CONFIG=/workspace/config -DZMK_EXTRA_MODULES=/repo \
    ${shield:+-DSHIELD=\"$shield\"} $cmake_args"
  cp "build/$name/zephyr/zmk.uf2" "firmware/$name.uf2"
  built=$((built + 1))
done

if (( built == 0 )); then
  echo "No build.yaml target matched: ${targets[*]}" >&2
  exit 1
fi
echo
ls -l firmware/*.uf2
