#!/usr/bin/env bash
# Regression tests for devora_check_sums in scripts/package-offline-installer.sh.
# The real producer functions are extracted from the script source (not copied); no archive,
# images, engine or network are used. Fixtures are kept under a fresh mktemp dir (path printed).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../scripts/package-offline-installer.sh"
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# Extract a top-level function definition (one-liner or block ending in a bare "}") by name.
extract_fn() {
  awk -v f="$1" '
    !on && index($0, f "() {") == 1 { on = 1; print; if ($0 ~ /}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*$/) exit; next }
    on { print; if ($0 == "}") exit }
  ' "$SRC"
}

FUNCS=""
for f in die sha256_of regular_file is_hex64 devora_check_sums; do
  body="$(extract_fn "$f")"
  [ -n "$body" ] || { echo "could not extract $f from $SRC" >&2; exit 1; }
  FUNCS="$FUNCS$body"$'\n'
done
eval "$FUNCS"
type devora_check_sums >/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-offline-media-checksums.XXXXXX")"
echo "fixtures: $ROOT (retained)"

PASS=0
FAIL=0

# new_case -> prints a fresh media dir; outputs live beside it, not inside it
new_case() {
  local d
  d="$(mktemp -d "$ROOT/case.XXXXXX")"
  mkdir -p "$d/media" "$d/out"
  printf '%s\n' "$d"
}

run_check() { # case-dir -> rc; stderr to case-dir/err
  local c="$1"
  set +e
  ( STAGE=""; devora_check_sums "$c/media" "$c/out/names" ) 2> "$c/err"
  local rc=$?
  set -e
  return "$rc"
}

ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1" >&2; [ -n "${2:-}" ] && sed 's/^/       /' "$2" >&2; return 0; }

expect_fail() { # name case-dir stderr-fragment
  if run_check "$2"; then
    bad "$1 (accepted)"
  elif grep -qF -- "$3" "$2/err"; then
    ok "$1"
  else
    bad "$1 (wrong error)" "$2/err"
  fi
}

# write a valid entry for an existing file: entry media-dir name [sep]
entry() { printf '%s%s%s\n' "$(sha256_of "$1/$2")" "${3:-  }" "$2" >> "$1/SHA256SUMS"; }

HANGUL="my file 한글 미디어.bin"
ZERO="0000000000000000000000000000000000000000000000000000000000000000"

# --- success: spaces + Hangul, normal and binary separators, nested dir ---
c="$(new_case)"; m="$c/media"
printf 'alpha\n' > "$m/$HANGUL"
mkdir -p "$m/sub dir"; printf 'beta\n' > "$m/sub dir/b.bin"
entry "$m" "$HANGUL" '  '
entry "$m" "sub dir/b.bin" ' *'
if run_check "$c"; then
  if [ "$(sed -n 1p "$c/out/names")" = "$HANGUL" ] && [ "$(sed -n 2p "$c/out/names")" = "sub dir/b.bin" ] \
     && [ "$(wc -l < "$c/out/names" | tr -d ' ')" = 2 ] && [ ! -e "$c/out/names.found" ]; then
    ok "accepts spaces+Hangul name, '  ' and ' *' separators; byte-exact names written"
  else
    bad "success output names" "$c/out/names"
  fi
else
  bad "success case rejected" "$c/err"
fi

# --- duplicate path ---
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
entry "$m" a.bin; entry "$m" a.bin ' *'
expect_fail "duplicate path" "$c" "중복 경로"

# --- uncovered file ---
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"; printf 'x\n' > "$m/extra.bin"
entry "$m" a.bin
expect_fail "uncovered extra file" "$c" "정확히 대응하지 않습니다"

# --- hash mismatch (valid hex) ---
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
printf '%s  a.bin\n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "hash mismatch" "$c" "해시 불일치"

# --- uppercase / short hash ---
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
printf '%s  a.bin\n' "$(sha256_of "$m/a.bin" | tr 'a-f' 'A-F')" > "$m/SHA256SUMS"
expect_fail "uppercase hash" "$c" "64자리 소문자 hex"
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
printf 'abc123  a.bin\n' > "$m/SHA256SUMS"
expect_fail "short hash" "$c" "64자리 소문자 hex"

# --- bad separators: single space, tab ---
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
entry "$m" a.bin ' '
expect_fail "single-space separator" "$c" "구분자"
c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"
entry "$m" a.bin $'\t'
expect_fail "tab separator" "$c" "구분자"

# --- empty name ---
c="$(new_case)"; m="$c/media"
printf '%s  \n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "empty name" "$c" "파일명이 비어"

# --- missing / non-regular / symlink targets ---
c="$(new_case)"; m="$c/media"
printf '%s  missing.bin\n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "missing target" "$c" "파일이 없습니다"
c="$(new_case)"; m="$c/media"; mkdir "$m/d"
printf '%s  d\n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "directory target" "$c" "파일이 없습니다"
c="$(new_case)"; m="$c/media"; printf 'real\n' > "$c/out-of-tree.bin"
ln -s "$c/out-of-tree.bin" "$m/link.bin"
printf '%s  link.bin\n' "$(sha256_of "$c/out-of-tree.bin")" > "$m/SHA256SUMS"
expect_fail "symlink target" "$c" "파일이 없습니다"

# --- unsafe paths: traversal, absolute, dot, backslash, trailing slash, self, control ---
for p in "../a.bin" "sub/../a.bin" "/etc/hosts" "./a.bin" 'sub\a.bin' "sub/" "sub//a.bin" "SHA256SUMS"; do
  c="$(new_case)"; m="$c/media"; printf 'a\n' > "$m/a.bin"; mkdir -p "$m/sub"
  printf '%s  %s\n' "$ZERO" "$p" > "$m/SHA256SUMS"
  expect_fail "unsafe path: $p" "$c" "안전하지 않은 경로"
done
c="$(new_case)"; m="$c/media"
printf '%s  a\tb.bin\n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "control char (tab) in path" "$c" "제어 문자"
c="$(new_case)"; m="$c/media"
printf '%s  a.bin\r\n' "$ZERO" > "$m/SHA256SUMS"
expect_fail "control char (CR) in path" "$c" "제어 문자"

echo "passed=$PASS failed=$FAIL fixtures=$ROOT"
[ "$FAIL" -eq 0 ]
