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
