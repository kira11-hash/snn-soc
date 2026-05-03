#!/usr/bin/env bash

resolve_iverilog_tools() {
  if command -v iverilog >/dev/null 2>&1; then
    IVERILOG_BIN="$(command -v iverilog)"
  elif command -v iverilog.exe >/dev/null 2>&1; then
    IVERILOG_BIN="$(command -v iverilog.exe)"
  else
    echo "[ERROR] iverilog not found in PATH" >&2
    return 127
  fi

  if command -v vvp >/dev/null 2>&1; then
    VVP_BIN="$(command -v vvp)"
  elif command -v vvp.exe >/dev/null 2>&1; then
    VVP_BIN="$(command -v vvp.exe)"
  else
    echo "[ERROR] vvp not found in PATH" >&2
    return 127
  fi

  IVERILOG_NEEDS_WINPATH=0
  VVP_NEEDS_WINPATH=0
  if [ -n "${WSL_DISTRO_NAME:-}" ] && [[ "$IVERILOG_BIN" == *.exe ]]; then
    IVERILOG_NEEDS_WINPATH=1
  fi
  if [ -n "${WSL_DISTRO_NAME:-}" ] && [[ "$VVP_BIN" == *.exe ]]; then
    VVP_NEEDS_WINPATH=1
  fi
}

resolve_python_tool() {
  if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v python.exe >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python.exe)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python.exe >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python.exe)"
  else
    echo "[ERROR] python not found in PATH" >&2
    return 127
  fi
}

to_host_path() {
  local path="$1"
  local abs

  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    printf '%s\n' "$path"
    return 0
  fi

  case "$path" in
    /*)
      abs="$path"
      ;;
    *)
      abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
      ;;
  esac

  wslpath -w "$abs" | tr -d '\r'
}

run_iverilog() {
  local args=()
  local expect_path=0
  local arg

  for arg in "$@"; do
    if [ "$expect_path" -eq 1 ]; then
      if [ "$IVERILOG_NEEDS_WINPATH" -eq 1 ]; then
        args+=("$(to_host_path "$arg")")
      else
        args+=("$arg")
      fi
      expect_path=0
      continue
    fi

    case "$arg" in
      -f|-o|-I|-y|-Y)
        args+=("$arg")
        expect_path=1
        ;;
      *)
        args+=("$arg")
        ;;
    esac
  done

  "$IVERILOG_BIN" "${args[@]}"
}

run_vvp() {
  local args=("$@")
  if [ "$VVP_NEEDS_WINPATH" -eq 1 ] && [ "$#" -ge 1 ]; then
    args[0]="$(to_host_path "$1")"
  fi
  "$VVP_BIN" "${args[@]}"
}

run_python() {
  "$PYTHON_BIN" "$@"
}

to_windows_path() {
  local path="$1"
  local abs

  case "$path" in
    /*)
      abs="$path"
      ;;
    *)
      abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
      ;;
  esac

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$abs" | tr -d '\r'
    return 0
  fi

  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$abs" | tr -d '\r'
    return 0
  fi

  printf '%s\n' "$abs"
}

find_weight_dir() {
  local root_dir="$1"
  local fallback_dir="${2:-}"
  local auto_export_pos
  local dir

  auto_export_pos=$(find "$root_dir" -path '*/results/exports/weight_pos.hex' ! -path '*/backups/*' -print -quit 2>/dev/null || true)
  if [ -n "$auto_export_pos" ] && [ -f "${auto_export_pos%/weight_pos.hex}/weight_neg.hex" ]; then
    printf '%s\n' "${auto_export_pos%/weight_pos.hex}"
    return 0
  fi

  auto_export_pos=$(find "$root_dir" -path '*/results/exports/weight_pos.hex' -print -quit 2>/dev/null || true)
  if [ -n "$auto_export_pos" ] && [ -f "${auto_export_pos%/weight_pos.hex}/weight_neg.hex" ]; then
    printf '%s\n' "${auto_export_pos%/weight_pos.hex}"
    return 0
  fi

  for dir in "$root_dir/fpga/cim_model" "$fallback_dir"; do
    [ -n "$dir" ] || continue
    if [ -f "$dir/weight_pos.hex" ] && [ -f "$dir/weight_neg.hex" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  return 1
}

find_stimulus_dir() {
  local root_dir="$1"
  local fallback_dir="${2:-}"
  local auto_stimulus
  local dir

  auto_stimulus=$(find "$root_dir" -path '*/rtl_stimulus/all_samples.hex' ! -path '*/backups/*' -print -quit 2>/dev/null || true)
  if [ -n "$auto_stimulus" ] && [ -f "${auto_stimulus%/all_samples.hex}/expected_classes.hex" ]; then
    printf '%s\n' "${auto_stimulus%/all_samples.hex}"
    return 0
  fi

  auto_stimulus=$(find "$root_dir" -path '*/rtl_stimulus/all_samples.hex' -print -quit 2>/dev/null || true)
  if [ -n "$auto_stimulus" ] && [ -f "${auto_stimulus%/all_samples.hex}/expected_classes.hex" ]; then
    printf '%s\n' "${auto_stimulus%/all_samples.hex}"
    return 0
  fi

  for dir in "$fallback_dir"; do
    [ -n "$dir" ] || continue
    if [ -f "$dir/all_samples.hex" ] && [ -f "$dir/expected_classes.hex" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  return 1
}

find_vendor_e203_rtl_dir() {
  local root_dir="$1"
  local preferred_dir
  local found_dir

  preferred_dir="$root_dir/项目相关文件/未添加的IP的源代码/e203_hbirdv2-master/rtl"
  if [ -d "$preferred_dir" ]; then
    printf '%s\n' "$preferred_dir"
    return 0
  fi

  found_dir=$(find "$root_dir" -type d -path '*/e203_hbirdv2-master/rtl' \
    ! -path '*/oldverision/*' ! -path '*/oldversion/*' ! -path '*/backups/*' \
    -print -quit 2>/dev/null || true)
  if [ -n "$found_dir" ]; then
    printf '%s\n' "$found_dir"
    return 0
  fi

  find "$root_dir" -type d -path '*/e203_hbirdv2-master/rtl' -print -quit 2>/dev/null || true
}

ensure_vendor_e203_alias() {
  local root_dir="$1"
  local alias_dir="$root_dir/rtl/vendor_e203"
  local alias_win
  local vendor_src_posix
  local vendor_src_win

  VENDOR_E203_ALIAS_CREATED="${VENDOR_E203_ALIAS_CREATED:-0}"
  VENDOR_E203_ALIAS_PATH="${VENDOR_E203_ALIAS_PATH:-}"

  if [ -e "$alias_dir" ]; then
    VENDOR_E203_ALIAS_PATH="$alias_dir"
    return 0
  fi

  vendor_src_posix="$(find_vendor_e203_rtl_dir "$root_dir")"
  if [ -z "$vendor_src_posix" ]; then
    echo "[ERROR] Unable to locate e203_hbirdv2-master/rtl under repo root: $root_dir" >&2
    return 1
  fi

  alias_win="$(to_windows_path "$alias_dir")"
  alias_win="${alias_win//\//\\}"
  vendor_src_win="$(to_windows_path "$vendor_src_posix")"
  vendor_src_win="${vendor_src_win//\//\\}"

  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "[ERROR] powershell.exe not found; cannot create rtl/vendor_e203 junction" >&2
    return 1
  fi

  powershell.exe -NoProfile -Command \
    "if (-not (Test-Path '$alias_win')) { New-Item -ItemType Junction -Path '$alias_win' -Target '$vendor_src_win' | Out-Null }"

  VENDOR_E203_ALIAS_CREATED=1
  VENDOR_E203_ALIAS_PATH="$alias_dir"
}

cleanup_vendor_e203_alias() {
  local alias_path="${VENDOR_E203_ALIAS_PATH:-}"
  local alias_win

  if [ "${VENDOR_E203_ALIAS_CREATED:-0}" -ne 1 ] || [ -z "$alias_path" ]; then
    return 0
  fi

  alias_win="$(to_windows_path "$alias_path")"
  alias_win="${alias_win//\//\\}"
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c rmdir "$alias_win" > /dev/null 2>&1 || true
}

run_in_repo_wsl() {
  local root_dir="$1"
  shift
  local repo_wsl
  local repo_win
  local drive
  local rest

  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    repo_wsl="$root_dir"
    bash -lc "cd '$repo_wsl' && $*"
    return $?
  fi

  if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "[ERROR] wsl.exe not found; cannot run repo command in WSL" >&2
    return 127
  fi

  repo_win="$(to_windows_path "$root_dir")"
  if [[ "$repo_win" =~ ^([A-Za-z]):\\(.*)$ ]]; then
    drive="${BASH_REMATCH[1]}"
    drive="${drive,,}"
    rest="${BASH_REMATCH[2]//\\//}"
    repo_wsl="/mnt/$drive/$rest"
  else
    repo_wsl="$(wsl.exe wslpath -a "$repo_win" 2>/dev/null | tr -d '\r')"
    if [ -z "$repo_wsl" ]; then
      echo "[ERROR] unable to resolve WSL path for repo root: $root_dir" >&2
      return 1
    fi
  fi

  wsl.exe bash -lc "cd '$repo_wsl' && $*"
}
