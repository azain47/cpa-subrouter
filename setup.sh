#!/usr/bin/env bash
# CPA Sub Router — stack Claude / OpenAI subscription accounts in CLIProxyAPI
# with fill-first routing: account 1 until it hits its limit, then account 2, ...
#
# Run without installing anything:
#   bash <(curl -fsSL https://raw.githubusercontent.com/azain47/cpa-subrouter/main/setup.sh)
#
# Options:
#   --config PATH   CLIProxyAPI config file (default: $CLIPROXYAPI_CONFIG or auto-detect)
#   --bin PATH      cliproxyapi binary      (default: $CLIPROXYAPI_BIN or auto-detect)
#   -h, --help      Show this help
#
# Boxes, tables and prompts use gum (github.com/charmbracelet/gum). A pinned,
# checksum-verified copy is downloaded to a temp dir and deleted on exit.
#
# Everything runs from main(), invoked on the last line, so `curl ... | bash`
# parses the whole file before stdin is re-attached to the terminal.

set -Eeuo pipefail

GUM_VERSION="2.0.2"
REMOVED_DIR="$HOME/.cli-proxy-api-removed"
ISSUES_URL="https://github.com/azain47/cpa-subrouter/issues"

CLAUDE_COLOR="#D97757"
OPENAI_COLOR="#10A37F"
ACCENT="212"
MUTED="245"

# Indent every menu by one column so it lines up with the bordered panels.
export GUM_CHOOSE_PADDING="0 1"

config="${CLIPROXYAPI_CONFIG:-}"
bin="${CLIPROXYAPI_BIN:-}"
auth_dir=""
backup=""
work_dir=""
GUM=""
BANNER=""
KEY=""
ALT_SCREEN=0
STTY_SAVED=""
DIE_MSG=""
LAST_ERR=""

usage() {
  cat <<'EOF'
CPA Sub Router — stack Claude / OpenAI subscription accounts in CLIProxyAPI
with fill-first routing (one account until its limit, then the next).

Usage:
  bash <(curl -fsSL https://raw.githubusercontent.com/azain47/cpa-subrouter/main/setup.sh)
  bash <(curl -fsSL .../setup.sh) --config /path/to/config.yaml

Options:
  --config PATH   CLIProxyAPI config file (default: $CLIPROXYAPI_CONFIG or auto-detect)
  --bin PATH      cliproxyapi binary      (default: $CLIPROXYAPI_BIN or auto-detect)
  -h, --help      Show this help
EOF
}

# ─── terminal ───────────────────────────────────────────────────────────────

enter_screen() {
  STTY_SAVED="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true # stray keypresses between prompts don't print
  printf '\033[?1049h\033[H'     # alternate screen: the user's scrollback is untouched
  ALT_SCREEN=1
}

leave_screen() {
  if ((ALT_SCREEN)); then
    printf '\033[?25h\033[?1049l'
    ALT_SCREEN=0
  fi
  if [[ -n "$STTY_SAVED" ]]; then
    stty "$STTY_SAVED" 2>/dev/null || true
    STTY_SAVED=""
  fi
}

# Run a child program with the terminal in its normal mode (echo on).
with_tty_echo() {
  local saved status=0
  saved="$(stty -g 2>/dev/null || true)"
  if [[ -n "$STTY_SAVED" ]]; then stty "$STTY_SAVED" 2>/dev/null || true; fi
  "$@" || status=$?
  if [[ -n "$saved" ]]; then stty "$saved" 2>/dev/null || true; fi
  return "$status"
}

# Messages are printed by cleanup(), after the alternate screen is left.
die() {
  DIE_MSG="$*"
  exit 1
}

cleanup() {
  local status=$?
  leave_screen
  if [[ -n "$DIE_MSG" ]]; then
    printf '\033[31m✖ %s\033[0m\n' "$DIE_MSG" >&2
  elif ((status != 0 && status != 130)); then
    printf '\033[31m✖ Unexpected error (exit %s)%s\033[0m\n' "$status" "${LAST_ERR:+ at $LAST_ERR}" >&2
    printf '  Please report it: %s\n' "$ISSUES_URL" >&2
  fi
  if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi
  return 0
}

# Draw a whole frame in place: cursor home, overwrite each line, clear the
# rest. Nothing is erased first, so the screen never flashes blank.
show() {
  local frame="${1//$'\n'/$'\033[K\n'}"
  printf '\033[H%s\033[K\n\033[J' "$frame"
}

# One keypress → KEY (up, down, enter, esc, backspace, or the character).
read_key() {
  local k="" rest=""
  IFS= read -rsn1 k || { KEY=esc; return 0; }
  case "$k" in
    $'\e')
      rest="$(read_pending)"
      case "$rest" in
        "") KEY=esc ;;
        "[A" | "OA") KEY=up ;;
        "[B" | "OB") KEY=down ;;
        *) KEY=other ;;
      esac
      ;;
    "" | $'\n' | $'\r') KEY=enter ;;
    $'\x7f' | $'\b') KEY=backspace ;;
    *) KEY="$k" ;;
  esac
}

# Bytes queued right after ESC (arrow keys send ESC [ A). Waits at most 0.1s,
# so a lone Esc responds immediately — bash 3.2's `read -t` only takes whole seconds.
read_pending() {
  local saved
  saved="$(stty -g)"
  stty -icanon -echo min 0 time 1
  dd bs=1 count=2 2>/dev/null || true
  stty "$saved"
}

# ─── gum bootstrap ──────────────────────────────────────────────────────────

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

ensure_gum() {
  local found os arch sha asset
  # type -P: the gum() wrapper below would shadow `command -v gum`.
  found="$(type -P gum 2>/dev/null || true)"
  if [[ -n "$found" ]] && "$found" --version 2>/dev/null | grep -q ' v2\.'; then
    GUM="$found"
    return
  fi

  case "$(uname -s)" in
    Darwin) os=Darwin ;;
    Linux) os=Linux ;;
    *) die "Unsupported OS: $(uname -s). Install gum v2 manually, then re-run." ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) die "Unsupported CPU: $(uname -m). Install gum v2 manually, then re-run." ;;
  esac
  case "${os}_${arch}" in
    Darwin_arm64) sha=4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890 ;;
    Darwin_x86_64) sha=5374966c7c7199ea879fcaa525ddc6d447a098d3d35496e430a9a1ef38d30485 ;;
    Linux_arm64) sha=8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5 ;;
    Linux_x86_64) sha=d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2 ;;
  esac

  asset="gum_${GUM_VERSION}_${os}_${arch}"
  work_dir="$(mktemp -d)"
  printf '\033[2m  Preparing UI (gum %s, temporary)…\033[0m\n' "$GUM_VERSION"
  curl -fsSL --connect-timeout 15 --retry 2 -o "$work_dir/gum.tgz" \
    "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${asset}.tar.gz" ||
    die "Could not download gum. Check your internet connection."
  [[ "$(sha256_of "$work_dir/gum.tgz")" == "$sha" ]] || die "gum checksum mismatch; refusing to run it."
  tar -xzf "$work_dir/gum.tgz" -C "$work_dir"
  GUM="$work_dir/$asset/gum"
}

# style/table output is captured with $(...) and nested into other boxes;
# force color so gum doesn't strip it when stdout isn't a terminal.
gum() {
  case "$1" in
    style | table) CLICOLOR_FORCE=1 "$GUM" "$@" ;;
    *) "$GUM" "$@" ;;
  esac
}

# ─── styling (pure bash, no subprocesses) ───────────────────────────────────

# sgr COLOR [bold|faint|italic]... → ANSI start sequence. COLOR is a 256-color
# number or #RRGGBB. Empty when NO_COLOR is set.
sgr() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  local color="$1" codes="" attr
  shift
  for attr in "$@"; do
    case "$attr" in
      bold) codes+="1;" ;;
      faint) codes+="2;" ;;
      italic) codes+="3;" ;;
    esac
  done
  case "$color" in
    "") ;;
    \#*) codes+="38;2;$((16#${color:1:2}));$((16#${color:3:2}));$((16#${color:5:2}))" ;;
    *) codes+="38;5;$color" ;;
  esac
  printf '\033[%sm' "${codes%;}"
}

RESET=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && RESET=""

paint() { # color text [attrs...]
  local color="$1" text="$2"
  shift 2
  printf '%s%s%s' "$(sgr "$color" "$@")" "$text" "$RESET"
}

ok() { printf '  %s\n' "$(paint 10 "✔ $*")"; }
warn() { printf '  %s\n' "$(paint 11 "▲ $*")"; }
note() { printf '    %s\n' "$(paint "$MUTED" "$*")"; }

pause() {
  printf '\n  %s' "$(paint "$MUTED" "Press any key to continue…")"
  read_key
  echo
}

# Every box is at most 80 columns wide: keep panel lines ≤ 72 characters.
build_banner() {
  BANNER="$(gum style --border rounded --border-foreground "$ACCENT" --padding "0 2" --margin "1 1 0 1" \
    "$(paint "$ACCENT" '◆ CPA Sub Router' bold)" \
    "$(paint "$MUTED" 'Stack subscriptions in CLIProxyAPI — one fills up, the next takes over')")"
}

panel() { # title color lines... → bordered box (printed; capture with $(...))
  local title="$1" color="$2"
  shift 2
  gum style --border rounded --border-foreground "$color" --padding "0 2" --margin "0 1" \
    "$(paint "$color" "$title" bold)" "" "$@"
}

# Full-screen page: banner + optional panel, drawn in one write.
page() { # [title color lines...]
  if (($# == 0)); then
    show "$BANNER"$'\n'
  else
    show "$BANNER"$'\n\n'"$(panel "$@")"$'\n'
  fi
}

provider_label() { if [[ "$1" == claude ]]; then echo "Claude"; else echo "OpenAI"; fi; }
provider_color() { if [[ "$1" == claude ]]; then echo "$CLAUDE_COLOR"; else echo "$OPENAI_COLOR"; fi; }

# ─── config (YAML) ──────────────────────────────────────────────────────────
# CLIProxyAPI's config is flat YAML: top-level keys at column 0 and `routing:`
# as an indented block. The readers handle CRLF, comments and quoted scalars;
# check_config_layout() refuses layouts the writer can't edit safely.

YAML_AWK_LIB='
function strip_cr(s) { sub(/\r$/, "", s); return s }
function scalar(v,   q, rest, p) {
  sub(/^[ \t]+/, "", v)
  q = substr(v, 1, 1)
  if (q == "\"" || q == "\047") {
    rest = substr(v, 2)
    p = index(rest, q)
    return p ? substr(rest, 1, p - 1) : rest
  }
  if (v ~ /^#/) return ""
  sub(/[ \t]+#.*$/, "", v)
  sub(/[ \t]+$/, "", v)
  return v
}
function is_routing_line(s) { return s ~ /^routing:[ \t]*(#.*)?$/ }
'

yaml_root() { # key → value of a top-level key
  awk -v key="$1" "$YAML_AWK_LIB"'
    { line = strip_cr($0) }
    index(line, key ":") == 1 { print scalar(substr(line, length(key) + 2)); exit }
  ' "$config"
}

routing_value() { # key [file] → value of routing.<key>
  awk -v key="$1" "$YAML_AWK_LIB"'
    { line = strip_cr($0) }
    inblock && line ~ /^[^ \t#]/ { exit }
    inblock && line ~ /^[ \t]+[^ \t#]/ {
      match(line, /^[ \t]+/)
      ind = substr(line, 1, RLENGTH)
      if (cind == "") cind = ind
      if (ind == cind && index(substr(line, RLENGTH + 1), key ":") == 1) {
        print scalar(substr(line, RLENGTH + length(key) + 2))
        exit
      }
    }
    is_routing_line(line) { inblock = 1 }
  ' "${2:-$config}"
}

check_config_layout() {
  local layout
  layout="$(awk "$YAML_AWK_LIB"'
    { line = strip_cr($0) }
    line ~ /^[ \t]*(#.*)?$/ || line == "---" { next }
    !checked { checked = 1; if (line ~ /^[ \t]/) { print "indented"; exit } }
    line ~ /^routing:/ && !is_routing_line(line) { print "inline"; exit }
  ' "$config")"
  case "$layout" in
    indented) die "$config indents its top-level keys; CPA Sub Router can only edit configs whose top-level keys start at column 0." ;;
    inline) die "$config writes routing inline (routing: {...}). Change it to a block — 'routing:' on its own line, then '  strategy: fill-first' — and re-run." ;;
  esac
}

strategy_now() {
  local s
  s="$(routing_value strategy)"
  echo "${s:-round-robin}"
}

backup_config() {
  [[ -n "$backup" ]] && return 0
  backup="$config.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$config" "$backup"
}

# Set routing.strategy and routing.session-affinity, keeping the block's
# indentation, comments and line endings. The result is verified before it
# replaces the config.
write_routing() { # strategy affinity(true|false)
  local tmp
  backup_config
  tmp="$(mktemp "$config.XXXXXX")"
  awk -v strategy="$1" -v affinity="$2" "$YAML_AWK_LIB"'
    FNR == 1 { pass++ }
    pass == 1 {
      line = strip_cr($0)
      if ($0 ~ /\r$/) crlf = 1
      if (inblock && line ~ /^[^ \t#]/) inblock = 0
      if (inblock && line ~ /^[ \t]+[^ \t#]/) {
        match(line, /^[ \t]+/)
        ind = substr(line, 1, RLENGTH)
        if (cind == "") cind = ind
        if (ind == cind && index(substr(line, RLENGTH + 1), "strategy:") == 1) has_s = 1
        if (ind == cind && index(substr(line, RLENGTH + 1), "session-affinity:") == 1) has_a = 1
      }
      if (is_routing_line(line)) { inblock = 1; found = 1 }
      next
    }
    pass == 2 && FNR == 1 {
      eol = crlf ? "\r" : ""
      if (cind == "") cind = "  "
      inblock = 0
    }
    {
      line = strip_cr($0)
      if (inblock && line ~ /^[^ \t#]/) inblock = 0
      if (inblock && index(line, cind "strategy:") == 1) { print cind "strategy: \"" strategy "\"" eol; next }
      if (inblock && index(line, cind "session-affinity:") == 1) { print cind "session-affinity: " affinity eol; next }
      print
      if (is_routing_line(line)) {
        inblock = 1
        if (!has_s) print cind "strategy: \"" strategy "\"" eol
        if (!has_a) print cind "session-affinity: " affinity eol
      }
    }
    END {
      if (!found) {
        if (cind == "") cind = "  "
        print "routing:" eol
        print cind "strategy: \"" strategy "\"" eol
        print cind "session-affinity: " affinity eol
      }
    }
  ' "$config" "$config" >"$tmp"

  if [[ "$(routing_value strategy "$tmp")" != "$1" || "$(routing_value session-affinity "$tmp")" != "$2" ]]; then
    rm -f "$tmp"
    warn "Couldn't update routing in $config — it was left unchanged."
    note "Set it by hand:  routing: → strategy: $1, session-affinity: $2"
    return 1
  fi
  cat "$tmp" >"$config" # keep the file's permissions, owner and symlinks
  rm -f "$tmp"
}

# ─── locate cliproxyapi ─────────────────────────────────────────────────────

find_bin() {
  [[ -n "$bin" ]] && return 0
  bin="$(type -P cliproxyapi 2>/dev/null || true)"
  local candidate
  for candidate in "$HOME/.local/bin/cliproxyapi" /opt/homebrew/bin/cliproxyapi /usr/local/bin/cliproxyapi \
    "$HOME/cliproxyapi/cli-proxy-api"; do
    if [[ -z "$bin" && -x "$candidate" ]]; then bin="$candidate"; fi
  done
  return 0
}

# Config of a running CLIProxyAPI (`cliproxyapi -config PATH`), if any.
running_config() {
  ps axo command= 2>/dev/null | awk '
    $1 ~ /(^|\/)(cliproxyapi|cli-proxy-api)$/ {
      for (i = 2; i <= NF; i++) {
        if (($i == "-config" || $i == "--config") && i < NF) { print $(i + 1); exit }
        if ($i ~ /^--?config=/) { sub(/^--?config=/, "", $i); print $i; exit }
      }
    }' || true
}

find_config() {
  [[ -n "$config" ]] && return 0
  local candidate
  for candidate in "$(running_config)" /opt/homebrew/etc/cliproxyapi.conf /usr/local/etc/cliproxyapi.conf \
    /home/linuxbrew/.linuxbrew/etc/cliproxyapi.conf "$HOME/cliproxyapi/config.yaml" \
    "$HOME/.cli-proxy-api/config.yaml" ./config.yaml; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then config="$candidate"; return 0; fi
  done
}

ensure_cliproxyapi() {
  find_bin
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    panel "CLIProxyAPI not found" 9 \
      "CPA Sub Router manages accounts for CLIProxyAPI, which isn't" \
      "installed yet. Project: https://github.com/router-for-me/CLIProxyAPI"
    echo
    if command -v brew >/dev/null 2>&1 && gum confirm "  Install it with Homebrew now?"; then
      brew install cliproxyapi
      bin="$(type -P cliproxyapi 2>/dev/null || true)"
      [[ -n "$bin" ]] || die "Homebrew install finished but cliproxyapi is not on PATH."
      ok "Installed CLIProxyAPI. Start it any time with: brew services start cliproxyapi"
    else
      die "Install CLIProxyAPI, then run this again (or pass --bin PATH)."
    fi
  fi

  find_config
  [[ -n "$config" ]] || die "No CLIProxyAPI config found. Pass --config PATH."
  [[ -f "$config" ]] || die "Config not found: $config"
  [[ -s "$config" ]] || die "$config is empty."
  check_config_layout
  [[ -w "$config" ]] || die "Can't write $config — fix its permissions (or use sudo for a system file)."
  [[ -w "$(dirname "$config")" ]] || die "Can't create a backup next to $config — its folder isn't writable."

  auth_dir="$(yaml_root auth-dir)"
  auth_dir="${auth_dir:-$HOME/.cli-proxy-api}"
  auth_dir="${auth_dir/#\~/$HOME}"
  mkdir -p "$auth_dir" 2>/dev/null || die "Can't create the auth folder $auth_dir."
  [[ -w "$auth_dir" ]] || die "Can't write to the auth folder $auth_dir."
}

proxy_listening() {
  local host port
  host="$(yaml_root host)"
  port="$(yaml_root port)"
  case "$host" in "" | 0.0.0.0 | "::" | "[::]") host=127.0.0.1 ;; esac
  (exec 3<>"/dev/tcp/$host/${port:-8317}") 2>/dev/null
}

# ─── accounts ───────────────────────────────────────────────────────────────
# CLIProxyAPI tries the highest top-level "priority" first; ties fall back to
# the file name (which contains a random hash). Fill-first gets distinct
# priorities to pin the order; round-robin gets equal ones, because
# CLIProxyAPI only rotates within the highest-priority group.

# Reads or sets one top-level key of a JSON object, leaving everything else
# byte-for-byte intact. Exit 2 when the file isn't a JSON object.
#   awk -v mode=get -v key=K           → prints the value (strings unquoted)
#   awk -v mode=set -v key=K -v val=V  → prints the document with K = V (V is raw JSON)
JSON_AWK='
{ s = s $0 "\n" }
END {
  n = length(s)
  i = 1
  while (i <= n && substr(s, i, 1) ~ /[ \t\r\n]/) i++
  if (substr(s, i, 1) != "{") exit 2
  bpos = i
  for (j = i; j <= n; j++) {
    c = substr(s, j, 1)
    if (instr) {
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") {
        instr = 0
        if (in_key) { curkey = substr(s, kstart + 1, j - kstart - 1); in_key = 0; after_key = 1 }
      }
      continue
    }
    if (c == "\"") {
      instr = 1
      if (depth == 1 && want_key) { in_key = 1; kstart = j; want_key = 0 }
    } else if (c == "{" || c == "[") {
      depth++
      if (depth == 1) want_key = 1
    } else if (c == "}" || c == "]") {
      if (depth == 1 && capturing) { vend = j - 1; capturing = 0 }
      depth--
      if (depth == 0) { epos = j; break }
    } else if (depth == 1) {
      if (c == ":" && after_key) {
        after_key = 0
        if (curkey == key && !found) { found = 1; capturing = 1; vstart = j + 1 }
      } else if (c == ",") {
        if (capturing) { vend = j - 1; capturing = 0 }
        want_key = 1
      }
    }
  }
  if (!epos) exit 2
  if (found) {
    while (vstart <= vend && substr(s, vstart, 1) ~ /[ \t\r\n]/) vstart++
    while (vend >= vstart && substr(s, vend, 1) ~ /[ \t\r\n]/) vend--
  }
  if (mode == "get") {
    if (!found) exit 0
    v = substr(s, vstart, vend - vstart + 1)
    if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
    print v
    exit 0
  }
  if (found) {
    out = substr(s, 1, vstart - 1) val substr(s, vend + 1)
  } else {
    k = bpos + 1
    while (k <= n && substr(s, k, 1) ~ /[ \t\r\n]/) k++
    out = substr(s, 1, bpos) "\"" key "\":" val (substr(s, k, 1) == "}" ? "" : ",") substr(s, bpos + 1)
  }
  printf "%s", out
}'

json_get() { awk -v mode=get -v key="$2" "$JSON_AWK" "$1" 2>/dev/null || true; }

list_auth() { find "$auth_dir" -maxdepth 1 -name "$1-*.json" -exec basename {} \; | sort; }

account_count() { list_auth "$1" | grep -c . || true; }

get_priority() {
  local p
  p="$(json_get "$auth_dir/$1" priority)"
  [[ "$p" =~ ^-?[0-9]+$ ]] || p=0
  echo "$p"
}

account_name() {
  local email
  email="$(json_get "$auth_dir/$1" email)"
  if [[ -n "$email" ]]; then echo "$email"; else echo "${1%.json}"; fi
}

current_order() {
  local f
  list_auth "$1" | while IFS= read -r f; do
    printf '%s\t%s\n' "$(get_priority "$f")" "$f"
  done | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2
}

# Rewrite atomically (temp file in the same folder, then rename) — CLIProxyAPI's
# watcher treats that as an update and ignores the non-.json temp file.
set_priority() { # file value
  local file="$1" value="$2" tmp
  [[ "$(json_get "$file" priority)" == "$value" ]] && return 0
  tmp="$(mktemp "$auth_dir/.cpa-subrouter.XXXXXX")"
  if awk -v mode=set -v key=priority -v val="$value" "$JSON_AWK" "$file" >"$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    warn "Skipped $(basename "$file"): it isn't a JSON object."
  fi
}

store_order() { # newline-separated file names, first = used first
  local order="$1" n i=0 f rr=0
  [[ "$(strategy_now)" == fill-first ]] || rr=1
  n="$(printf '%s\n' "$order" | grep -c . || true)"
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$auth_dir/$f" ]] && continue
    if ((rr)); then set_priority "$auth_dir/$f" 1; else set_priority "$auth_dir/$f" $((n - i)); fi
    i=$((i + 1))
  done <<<"$order"
}

sync_priorities() {
  store_order "$(current_order claude)"
  store_order "$(current_order codex)"
}

run_login() { # flag — Ctrl-C cancels the login only, not the whole script
  local status=0
  trap ':' INT
  with_tty_echo "$bin" -config "$config" "$1" || status=$?
  trap 'exit 130' INT
  return "$status"
}

# ─── screens ────────────────────────────────────────────────────────────────

status_block() { # printed; capture with $(...)
  local port strategy affinity proxy routing_line affinity_line
  port="$(yaml_root port)"
  strategy="$(strategy_now)"
  affinity="$(routing_value session-affinity)"

  if proxy_listening; then
    proxy="$(paint 10 "● running")  $(paint "$MUTED" "port ${port:-8317}")"
  else
    proxy="$(paint 9 "○ not running")  $(paint "$MUTED" "start it before using your tools")"
  fi
  if [[ "$strategy" == fill-first ]]; then
    routing_line="$(paint 10 "fill-first")  $(paint "$MUTED" "one account at a time")"
  else
    routing_line="$(paint 11 "$strategy")  $(paint "$MUTED" "requests spread across accounts")"
  fi
  if [[ "$affinity" == true ]]; then
    affinity_line="$(paint 11 "on")  $(paint "$MUTED" "chats stay on their account")"
  else
    affinity_line="$(paint 10 "off")  $(paint "$MUTED" "strict order")"
  fi

  echo
  printf '   %s  %s\n' "$(paint "" 'Proxy   ' bold)" "$proxy"
  printf '   %s  %s\n' "$(paint "" 'Routing ' bold)" "$routing_line"
  printf '   %s  %s\n' "$(paint "" 'Affinity' bold)" "$affinity_line"
  printf '   %s  %s\n' "$(paint "" 'Config  ' bold)" "$(paint "$MUTED" "$config")"
  echo

  local prefix f i rows="" role tab=$'\t'
  for prefix in claude codex; do
    i=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      i=$((i + 1))
      if [[ "$strategy" != fill-first ]]; then role="in rotation"
      elif ((i == 1)); then role="▶ used first"
      else role="backup $((i - 1))"; fi
      rows+="$(provider_label "$prefix")$tab$i$tab$(account_name "$f")$tab$role"$'\n'
    done <<<"$(current_order "$prefix")"
  done

  if [[ -z "$rows" ]]; then
    printf '   %s\n' "$(paint "$MUTED" "No accounts yet — add one below." italic)"
  else
    printf '%s' "$rows" | gum table --print --separator "$tab" --lazy-quotes --border rounded \
      --border.foreground "$ACCENT" --header.foreground "$ACCENT" --columns "Provider,#,Account,Role" |
      sed 's/^/ /'
  fi
}

has_accounts() { (($(account_count claude) + $(account_count codex) > 0)); }

pick_provider() { # [existing] → claude|codex; non-zero if cancelled
  local only_existing="${1:-}" options=() prefix
  for prefix in claude codex; do
    if [[ -z "$only_existing" ]] || (($(account_count "$prefix") > 0)); then
      options+=("$(provider_label "$prefix")|$prefix")
    fi
  done
  if ((${#options[@]} == 1)); then echo "${options[0]#*|}"; return 0; fi
  gum choose --header "Which provider?" --label-delimiter "|" --cursor "❯ " "${options[@]}"
}

add_account() {
  local prefix="$1" label color flag="-claude-login" site="claude.ai" before_order before new position
  local before_sums gone refreshed f
  label="$(provider_label "$prefix")"
  color="$(provider_color "$prefix")"
  local article="a"
  [[ "$prefix" == codex ]] && site="chatgpt.com" && article="an"

  while true; do
    page "Add $article $label account" "$color" \
      "1. A login page opens in your browser (or a link is printed below)." \
      "2. Sign in with a $(paint "" different bold) $label account than those already added." \
      "3. Come back here when the browser says you're done." \
      "" \
      "$(paint "$MUTED" "Tip: use a private window, or log out of $site first —")" \
      "$(paint "$MUTED" "otherwise the browser signs in to the same account again.")" \
      "$(paint "$MUTED" "Ctrl-C cancels the login.")"

    if [[ "$prefix" == codex ]]; then
      flag="$(gum choose --header "How do you want to sign in to OpenAI?" --label-delimiter "|" --cursor "❯ " \
        "Browser login (this computer)|-codex-login" \
        "Device code (remote / SSH machine)|-codex-device-login")" || return 0
    else
      gum confirm "  Start the $label login?" || return 0
    fi
    echo

    before_order="$(current_order "$prefix")"
    before="$(list_auth "$prefix")"
    before_sums="$(fingerprints "$prefix")"
    run_login "$flag" || true # the outcome is judged from the auth files below
    new="$(comm -13 <(printf '%s\n' "$before") <(list_auth "$prefix") | grep . || true)"
    gone="$(comm -23 <(printf '%s\n' "$before") <(list_auth "$prefix") | grep . || true)"
    # Files whose contents changed: the login refreshed an account already added.
    refreshed="$(comm -13 <(printf '%s\n' "$before_sums") <(fingerprints "$prefix") | cut -f2 |
      grep -vxF -f <(printf '%s\n' "$new" | grep . || echo /) || true)"

    if [[ -n "$new" && -n "$gone" && "$(printf '%s\n' "$new" | grep -c .)" == 1 &&
      "$(printf '%s\n' "$gone" | grep -c .)" == 1 ]]; then
      # CLIProxyAPI renamed an old-style file for the same account: keep its place.
      store_order "$(printf '%s\n' "$before_order" | while IFS= read -r f; do
        if [[ "$f" == "$gone" ]]; then printf '%s\n' "$new"; else printf '%s\n' "$f"; fi
      done)"
      refreshed="$new"
      new=""
    else
      # Also restores the priority if the login rewrote an existing account's file.
      store_order "$(printf '%s\n%s' "$before_order" "$new")"
    fi

    echo
    if [[ -n "$new" ]]; then
      position="it is used after your existing $label accounts"
      [[ "$(strategy_now)" == fill-first ]] || position="it joins the rotation"
      ok "Added $(account_name "$(printf '%s\n' "$new" | head -n 1)") — $position."
      pause
      return 0
    fi
    if [[ -n "$refreshed" ]]; then
      warn "$(account_name "$(printf '%s\n' "$refreshed" | head -n 1)") is already added — no duplicate was created."
      note "Its login was refreshed and it keeps its place in the order."
      note "To add a different account, sign out of $site first or use a private window."
    else
      warn "No $label account was saved — the login was cancelled or didn't finish."
    fi
    echo
    gum confirm "  Try again?" || return 0
  done
}

fingerprints() { # prefix → "cksum<TAB>file" per auth file, to spot rewritten ones
  local f
  list_auth "$1" | while IFS= read -r f; do
    printf '%s\t%s\n' "$(cksum <"$auth_dir/$f")" "$f"
  done | sort
}

# ↑/↓ highlights an account, a number key moves it to that position (the
# others shift), Enter saves, Esc/q cancels. Number keys reach positions 1-9.
reorder_accounts() {
  local prefix label color order=() names=() idx=() line i n cur=0 target moved changed max header body
  local c_cursor c_sel c_faint c_muted

  page
  if [[ "$(strategy_now)" != fill-first ]]; then
    warn "Order only matters with fill-first routing — switch in Routing settings."
    pause
    return 0
  fi
  if ! has_accounts; then
    warn "No accounts yet."
    pause
    return 0
  fi
  prefix="$(pick_provider existing)" || return 0
  label="$(provider_label "$prefix")"
  color="$(provider_color "$prefix")"
  while IFS= read -r line; do [[ -n "$line" ]] && order+=("$line"); done <<<"$(current_order "$prefix")"
  n=${#order[@]}
  if ((n < 2)); then
    warn "You need at least two $label accounts to change the order."
    pause
    return 0
  fi
  for ((i = 0; i < n; i++)); do
    names+=("$(account_name "${order[i]}")")
    idx+=("$i") # idx[position] = original index
  done
  max=$((n < 9 ? n : 9))

  # Everything static is rendered once; each keypress only rebuilds the list.
  header="$BANNER"$'\n\n'"$(panel "Reorder $label accounts" "$color" \
    "Used top to bottom: #1 until it hits its limit, then #2, and so on." \
    "$(paint "$MUTED" "Highlight an account with ↑/↓, then press its new position number.")")"$'\n\n'
  c_cursor="$(sgr "$ACCENT")"
  c_sel="$(sgr "$color" bold)"
  c_faint="$(sgr "" faint)"
  c_muted="$(sgr "$MUTED")"

  printf '\033[?25l'
  while true; do
    body=""
    for ((i = 0; i < n; i++)); do
      line="$((i + 1)). ${names[idx[i]]}"
      if ((i == cur)); then
        body+="  ${c_cursor}❯${RESET} ${c_sel}${line}${RESET}"
      else
        body+="    ${line}"
      fi
      if ((idx[i] != i)); then body+="  ${c_faint}(was #$((idx[i] + 1)))${RESET}"; fi
      body+=$'\n'
    done
    body+=$'\n'"   ${c_muted}↑/↓ select  •  1-$max move here  •  enter save  •  esc cancel${RESET}"
    show "$header$body"

    read_key
    case "$KEY" in
      up | k) if ((cur > 0)); then cur=$((cur - 1)); fi ;;
      down | j) if ((cur < n - 1)); then cur=$((cur + 1)); fi ;;
      [1-9])
        target=$((KEY - 1))
        if ((target < n && target != cur)); then
          moved="${idx[cur]}"
          if ((target < cur)); then
            for ((i = cur; i > target; i--)); do idx[i]="${idx[i - 1]}"; done
          else
            for ((i = cur; i < target; i++)); do idx[i]="${idx[i + 1]}"; done
          fi
          idx[target]="$moved"
          cur=$target
        fi
        ;;
      enter) break ;;
      esc | q | Q)
        printf '\033[?25h'
        return 0
        ;;
    esac
  done
  printf '\033[?25h'

  changed=false
  for ((i = 0; i < n; i++)); do if ((idx[i] != i)); then changed=true; fi; done
  echo
  if [[ "$changed" == false ]]; then
    note "Order unchanged."
    pause
    return 0
  fi
  store_order "$(for ((i = 0; i < n; i++)); do printf '%s\n' "${order[idx[i]]}"; done)"
  ok "New $label order saved:"
  for ((i = 0; i < n; i++)); do note "$((i + 1)). ${names[idx[i]]}"; done
  pause
}

remove_account() {
  local prefix label options=() f choice name dest
  page "Remove an account" 9 \
    "The account stops being used right away." \
    "$(paint "$MUTED" "Its credential file is moved to ~/${REMOVED_DIR#"$HOME"/} (not deleted);")" \
    "$(paint "$MUTED" "move it back into the auth folder to restore the account.")"
  if ! has_accounts; then
    warn "No accounts to remove."
    pause
    return 0
  fi
  prefix="$(pick_provider existing)" || return 0
  label="$(provider_label "$prefix")"
  while IFS= read -r f; do [[ -n "$f" ]] && options+=("$(account_name "$f")|$f"); done <<<"$(current_order "$prefix")"
  choice="$(gum choose --header "Remove which $label account?" --label-delimiter "|" --cursor "❯ " \
    "${options[@]}")" || return 0
  name="$(account_name "$choice")"
  gum confirm --default=false "  Remove $name?" || return 0

  mkdir -p "$REMOVED_DIR"
  chmod 700 "$REMOVED_DIR" 2>/dev/null || true
  dest="$REMOVED_DIR/$choice"
  # Never overwrite an earlier removed copy.
  if [[ -e "$dest" ]]; then dest="$REMOVED_DIR/${choice%.json}.$(date +%Y%m%d%H%M%S).json"; fi
  mv "$auth_dir/$choice" "$dest"
  store_order "$(current_order "$prefix")"
  echo
  ok "Removed $name."
  note "Saved to $dest"
  pause
}

routing_settings() {
  local strategy affinity current_s current_a
  page "Routing" "$ACCENT" \
    "$(paint "" "Fill-first " bold)  one account until its limit, then the next $(paint "$MUTED" "(recommended)")" \
    "$(paint "" "Round-robin" bold)  spread every request across all accounts" \
    "" \
    "$(paint "" "Session affinity" bold)  keep a conversation on the account it started on." \
    "$(paint "$MUTED" "Better prompt caching, but a chat can stay on a later account after")" \
    "$(paint "$MUTED" "an earlier one resets. Off: every request follows the order strictly.")"

  current_s="Fill-first"
  [[ "$(strategy_now)" == fill-first ]] || current_s="Round-robin"
  current_a="Off — strict order"
  [[ "$(routing_value session-affinity)" != true ]] || current_a="On — keep chats on their account"

  strategy="$(gum choose --header "Routing strategy" --label-delimiter "|" --cursor "❯ " --selected "$current_s" \
    "Fill-first|fill-first" \
    "Round-robin|round-robin")" || return 0
  affinity="$(gum choose --header "Session affinity" --label-delimiter "|" --cursor "❯ " --selected "$current_a" \
    "Off — strict order|false" \
    "On — keep chats on their account|true")" || return 0

  echo
  if write_routing "$strategy" "$affinity"; then
    sync_priorities
    ok "Routing: $strategy · session affinity: $([[ "$affinity" == true ]] && echo on || echo off)"
    note "CLIProxyAPI reloads the config automatically. Backup: $backup"
  fi
  pause
}

first_run_checks() {
  local strategy
  strategy="$(strategy_now)"
  if [[ "$strategy" != fill-first ]]; then
    page "Switch to fill-first routing?" "$ACCENT" \
      "Routing is currently $(paint "" "$strategy" bold): requests are spread across accounts." \
      "Fill-first uses one account until it hits its limit, then the next," \
      "so each subscription's usage window is used in turn." \
      "" \
      "$(paint "$MUTED" "Session affinity is turned off so the order is followed strictly.")"
    if gum confirm "  Switch to fill-first?"; then
      echo
      if write_routing fill-first false; then ok "Fill-first enabled (config backup: $backup)"; fi
      pause
    fi
  fi
  sync_priorities
}

main_menu() {
  local choice
  while true; do
    show "$BANNER"$'\n'"$(status_block)"$'\n'
    choice="$(gum choose --header "What would you like to do?" --label-delimiter "|" --cursor "❯ " --height 10 \
      "+ Add a Claude account|add-claude" \
      "+ Add an OpenAI (ChatGPT/Codex) account|add-codex" \
      "↕ Change account order|reorder" \
      "× Remove an account|remove" \
      "≡ Routing settings|routing" \
      "← Quit|quit")" || choice=quit

    case "$choice" in
      add-claude) add_account claude ;;
      add-codex) add_account codex ;;
      reorder) reorder_accounts ;;
      remove) remove_account ;;
      routing) routing_settings ;;
      quit) return 0 ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config | --bin)
        [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a path."
        if [[ "$1" == --config ]]; then config="$2"; else bin="$2"; fi
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

main() {
  ensure_gum
  ensure_cliproxyapi
  build_banner

  enter_screen
  first_run_checks
  main_menu
  leave_screen

  # Leave a summary in the normal terminal.
  status_block
  echo
  ok "All set. Accounts are used in the order shown above."
  echo
}

# `curl | bash` leaves stdin as the pipe, so read keys from the terminal. Use
# the real device (e.g. /dev/ttys003) rather than /dev/tty: on macOS gum can't
# cancel its key reader on /dev/tty and stalls ~0.5s after every prompt.
terminal_device() {
  local fd dev
  for fd in 2 1; do
    if dev="$(tty <&"$fd" 2>/dev/null)" && [[ "$dev" == /dev/* ]]; then
      echo "$dev"
      return 0
    fi
  done
  if { : </dev/tty; } 2>/dev/null; then echo /dev/tty; fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'LAST_ERR="line $LINENO: $BASH_COMMAND"' ERR

parse_args "$@"
if [[ -t 0 ]]; then
  main
else
  tty_dev="$(terminal_device)"
  [[ -n "$tty_dev" ]] || die "This setup is interactive — run it from a terminal."
  main <"$tty_dev"
fi
