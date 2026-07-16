#!/usr/bin/env bash
set -euo pipefail

readonly SECRET_PATTERN='[0-9a-f]{64}|Bearer [A-Za-z0-9._-]{20,}|BEGIN( RSA| OPENSSH)? PRIVATE KEY|hf_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{20,}|tskey-[A-Za-z0-9-]{20,}'
# Files whose purpose is recording SHA256 checksums are exempt from the
# 64-hex rule ONLY (they still get every other pattern via SECRET_PATTERN_NOHEX).
readonly SECRET_PATTERN_NOHEX='Bearer [A-Za-z0-9._-]{20,}|BEGIN( RSA| OPENSSH)? PRIVATE KEY|hf_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{20,}|tskey-[A-Za-z0-9-]{20,}'

is_checksum_file() {
  case "$1" in
    verification/MANIFEST.sha256|configs/versions.lock|configs/pins/*|evalsets/pins.json|results/transcripts/*|*.sha256) return 0 ;;
    *) return 1 ;;
  esac
}

# Split a NUL-delimited file list (stdin) into the two scan tiers.
split_files() {
  # sets globals: files_full, files_nohex
  files_full=()
  files_nohex=()
  local f
  while IFS= read -r -d '' f; do
    if is_checksum_file "$f"; then
      files_nohex+=("$f")
    else
      files_full+=("$f")
    fi
  done
}

gitleaks_binary() {
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks
  elif [[ -x bin/gitleaks ]]; then
    printf '%s\n' 'bin/gitleaks'
  fi
}

redact_matches() {
  sed -E \
    -e 's/([0-9a-f]{6})[0-9a-f]{58}/\1[REDACTED]/g' \
    -e 's/(Bearer)[ A-Za-z0-9._-]{21,}/\1[REDACTED]/g' \
    -e 's/(BEGIN )(RSA |OPENSSH )?PRIVATE KEY/\1[REDACTED]/g' \
    -e 's/(hf_[A-Za-z0-9]{3})[A-Za-z0-9]{27,}/\1[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9]{3})[A-Za-z0-9]{17,}/\1[REDACTED]/g' \
    -e 's/(tskey-)[A-Za-z0-9-]{20,}/\1[REDACTED]/g'
}

scan_stream() {
  local matches
  matches="$(grep -E "$SECRET_PATTERN" || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" | redact_matches >&2
    return 1
  fi
}

scan_staged() {
  local gitleaks
  gitleaks="$(gitleaks_binary || true)"
  if [[ -n "$gitleaks" ]]; then
    "$gitleaks" protect --staged
  fi

  # Diff base must exist even on an unborn branch (first commit), else zero
  # files are scanned and staged secrets pass silently.
  local diff_base
  diff_base="$(git rev-parse --verify --quiet HEAD || git hash-object -t tree /dev/null)"

  local -a files_full files_nohex
  split_files < <(git diff --cached --name-only --diff-filter=ACMR -z "$diff_base")
  if ((${#files_full[@]} == 0 && ${#files_nohex[@]} == 0)); then
    return 0
  fi

  local failed=0
  if ((${#files_full[@]} > 0)); then
    { git grep --cached -n -I -E "$SECRET_PATTERN" -- "${files_full[@]}" 2>/dev/null || true; } | scan_stream || failed=1
  fi
  if ((${#files_nohex[@]} > 0)); then
    { git grep --cached -n -I -E "$SECRET_PATTERN_NOHEX" -- "${files_nohex[@]}" 2>/dev/null || true; } | scan_stream || failed=1
  fi
  return "$failed"
}

scan_pushed_ref() {
  local local_sha="$1"
  local remote_sha="$2"
  local zero_sha='0000000000000000000000000000000000000000'
  local -a files_full files_nohex

  if [[ "$local_sha" == "$zero_sha" ]]; then
    return 0
  elif [[ "$remote_sha" == "$zero_sha" ]]; then
    split_files < <(git ls-tree -r --name-only -z "$local_sha")
  else
    split_files < <(git diff --name-only --diff-filter=ACMR -z "$remote_sha" "$local_sha")
  fi

  if ((${#files_full[@]} == 0 && ${#files_nohex[@]} == 0)); then
    return 0
  fi

  local failed=0
  if ((${#files_full[@]} > 0)); then
    { git grep -n -I -E "$SECRET_PATTERN" "$local_sha" -- "${files_full[@]}" 2>/dev/null || true; } \
      | sed -E "s/^${local_sha}://" \
      | scan_stream || failed=1
  fi
  if ((${#files_nohex[@]} > 0)); then
    { git grep -n -I -E "$SECRET_PATTERN_NOHEX" "$local_sha" -- "${files_nohex[@]}" 2>/dev/null || true; } \
      | sed -E "s/^${local_sha}://" \
      | scan_stream || failed=1
  fi
  return "$failed"
}

scan_push() {
  local gitleaks
  gitleaks="$(gitleaks_binary || true)"
  if [[ -n "$gitleaks" ]]; then
    "$gitleaks" detect
  fi

  local local_ref local_sha remote_ref remote_sha
  local failed=0
  while read -r local_ref local_sha remote_ref remote_sha; do
    if ! scan_pushed_ref "$local_sha" "$remote_sha"; then
      failed=1
    fi
  done
  return "$failed"
}

self_test() {
  local fake_secret
  fake_secret="$(printf 'a%.0s' {1..64})"
  if printf 'self-test.txt:1:%s\n' "$fake_secret" | scan_stream >/dev/null 2>&1; then
    printf '%s\n' 'self-test failed: fake secret was not detected' >&2
    return 1
  fi
  printf '%s\n' 'self-test passed'
}

case "${1:---staged}" in
  --staged)
    scan_staged
    ;;
  --pre-push)
    scan_push
    ;;
  --self-test)
    self_test
    ;;
  *)
    printf 'usage: %s [--staged|--pre-push|--self-test]\n' "$0" >&2
    exit 2
    ;;
esac
