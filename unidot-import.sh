#!/usr/bin/env bash
# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# SPDX-License-Identifier: MIT
#
# Import .unitypackage files (or Unity asset folders) from the command line,
# without opening the Godot editor window. See CLI.md.

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: unidot-import.sh [options] PACKAGE [PACKAGE...]

Imports each PACKAGE (.unitypackage, Unity asset folder or .meta file) into a
Godot project using a headless editor, then exits.

Options:
  -p, --project DIR        Godot project directory (default: the project this
                           addon is installed in, else the current directory)
  -g, --godot BIN          Godot executable (default: $GODOT, else "godot")
  -i, --include-type DESC  Also import this type, e.g. ".cs Script" (repeatable)
  -s, --skip-type DESC     Do not import this type, e.g. ".unity Scene" (repeatable)
  -t, --timeout SECONDS    Abort the import after this many seconds
  -l, --log FILE           Write all import warnings and errors to FILE
      --strict             Exit with code 1 if any asset reported errors
      --gui                Show the editor window during the import
  -h, --help               Show this help

Exit codes: 0 done, 1 errors (with --strict), 2 bad arguments, 3 timeout;
anything else comes from Godot itself (e.g. 134 for a crash).
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
godot="${GODOT:-godot}"
project=""
headless=(--headless)
unidot_args=()
packages=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		-p|--project) project="$2"; shift 2 ;;
		-g|--godot) godot="$2"; shift 2 ;;
		-i|--include-type) unidot_args+=("--unidot-include-type=$2"); shift 2 ;;
		-s|--skip-type) unidot_args+=("--unidot-skip-type=$2"); shift 2 ;;
		-t|--timeout) unidot_args+=("--unidot-timeout=$2"); shift 2 ;;
		-l|--log) unidot_args+=("--unidot-log=$(realpath -m -- "$2")"); shift 2 ;;
		--strict) unidot_args+=("--unidot-strict"); shift ;;
		--gui) headless=(); shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; packages+=("$@"); break ;;
		-*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) packages+=("$1"); shift ;;
	esac
done

if [[ ${#packages[@]} -eq 0 ]]; then
	usage >&2
	exit 2
fi

if [[ -z "$project" ]]; then
	# addons/unidot_importer/unidot-import.sh -> project root
	if [[ -f "$script_dir/../../project.godot" ]]; then
		project="$script_dir/../.."
	else
		project="."
	fi
fi
project="$(realpath -- "$project")"
if [[ ! -f "$project/project.godot" ]]; then
	echo "Not a Godot project: $project" >&2
	exit 2
fi

for pkg in "${packages[@]}"; do
	if [[ ! -e "$pkg" ]]; then
		echo "Package not found: $pkg" >&2
		exit 2
	fi
	# Godot runs inside the project directory, so pass absolute paths.
	unidot_args+=("--unidot-import=$(realpath -- "$pkg")")
done

exec "$godot" "${headless[@]}" --editor --path "$project" -- "${unidot_args[@]}"
