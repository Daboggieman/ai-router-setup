#!/usr/bin/env bash
# =============================================================================
# dahl-ant2oai-setup.sh  (fixed edition)
#
#   Claude Code (VS Code)  --Anthropic /v1/messages-->  a2o @ 127.0.0.1:3578
#        --OpenAI /v1/chat/completions-->  your provider (Dahl by default)
#
# What this script does
#   1. Lets you pick Dahl or a custom OpenAI-compatible endpoint + model
#   2. Installs a PINNED ant2oai (a2o) version into ~/ant2oia/.venv
#   3. Applies six small compatibility patches to a2o (seven file edits; each one checked first):
#        - parser.py   accept role="system" entries inside messages[]
#        - request.py  fold the system prompt into the first user message
#                      (for endpoints that reject role="system")
#        - response.py DeepSeek DSML tool calls -> Anthropic tool_use
#        - streaming.py same, for streamed responses
#        - request.py  strip regex lookahead/lookbehind "pattern" values from tool
#                      JSON schemas (upstream rejects them as invalid regex)
#        - streaming.py + response.py  read the model's reasoning from the "reasoning"
#                      field too (some providers, e.g. gonkarouter/vLLM, use that name
#                      instead of "reasoning_content"), so it reaches Claude Code as
#                      a "thinking" block instead of being silently dropped
#   4. Runs offline tests, then (optionally) a live smoke test
#   5. Writes config.env (600), a launcher, and your VS Code settings (comments in
#      settings.json are tolerated, with your consent), and optionally the Claude Code
#      thinking-display settings
#
# Safe to re-run. No sudo needed.
# =============================================================================

# shellcheck disable=SC1090
set -Eeuo pipefail

# ---------- configuration ----------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-$HOME/ant2oia}"
VENV_DIR="$INSTALL_DIR/.venv"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) VENV_BIN="$VENV_DIR/Scripts"; EXE=".exe" ;;
    *)                    VENV_BIN="$VENV_DIR/bin";     EXE="" ;;
esac
CONFIG_FILE="$INSTALL_DIR/config.env"
LAUNCHER="$INSTALL_DIR/start-a2o.sh"
PATCH_HELPER="$INSTALL_DIR/a2o_patch.py"
LOG_FILE="$INSTALL_DIR/a2o.log"
SETTINGS_HELPER="$INSTALL_DIR/a2o_settings.py"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DEFAULT_THINKING_TOKENS="16000"
BACKUPS_KEEP=5                  # settings.json backups to keep per file

# The patches were written and verified against this exact version.
A2O_VERSION="${A2O_VERSION:-0.1.6}"

A2O_HOST_DEFAULT="127.0.0.1"
A2O_PORT_DEFAULT="3578"
DEFAULT_BASE_URL="https://inference.dahl.global/v1/chat/completions"
DEFAULT_MODEL="zai-org/GLM-5.3-Flash"
PLACEHOLDER_TOKEN="a2o-local"   # used when the endpoint needs no key

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# ---------- colors / output --------------------------------------------------
if [[ -t 1 ]]; then
    BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    RED='\033[1;31m'; CYAN='\033[1;36m'; RESET='\033[0m'
else
    BLUE=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

info()    { printf '\n%b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"; }
success() { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$1"; }
warn()    { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1" >&2; }
error()   { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2; }
die()     { error "$1"; exit 1; }
section() {
    printf '\n%b============================================================%b\n' "$CYAN" "$RESET"
    printf '%b %s%b\n' "$CYAN" "$1" "$RESET"
    printf '%b============================================================%b\n' "$CYAN" "$RESET"
}

trap 'error "Failed at line $LINENO (exit code $?). Nothing after this point was run."' ERR
trap 'printf "\n"; warn "Interrupted."; exit 130' INT TERM

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t dahlsetup)"
SMOKE_PID=""
cleanup() {
    [[ -n "$SMOKE_PID" ]] && kill "$SMOKE_PID" 2>/dev/null || true
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

# ---------- input helpers ----------------------------------------------------
# IMPORTANT: prompts go to stderr. These helpers are called inside $(...), so a
# prompt printed to stdout would be captured into the variable and never shown.
prompt_default() {
    local prompt="$1" default="$2" value=""
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r value || die "Input closed."
    printf '%s' "${value:-$default}"
}

prompt_required() {
    local prompt="$1" value=""
    while true; do
        printf '%s: ' "$prompt" >&2
        read -r value || die "Input closed."
        if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
        warn "This value cannot be empty."
    done
}

prompt_secret() {
    local prompt="$1" value=""
    printf '%s: ' "$prompt" >&2
    read -r -s value || die "Input closed."
    printf '\n' >&2
    printf '%s' "$value"
}

confirm() {
    # confirm "Question" [Y|N default]
    local q="$1" def="${2:-Y}" hint reply=""
    if [[ "$def" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
    printf '%s [%s]: ' "$q" "$hint" >&2
    read -r reply || die "Input closed."
    reply="${reply:-$def}"
    [[ "$reply" =~ ^[Yy] ]]
}

normalize_upstream() {
    # Accepts a base URL or a full chat-completions URL; prints the full URL.
    local u="${1%/}" rest
    case "$u" in http://*|https://*) ;; *) return 1 ;; esac
    case "$u" in */chat/completions) printf '%s' "$u"; return 0 ;; esac
    rest="${u#*://}"
    if [[ "$rest" == */* ]]; then printf '%s/chat/completions' "$u"
    else printf '%s/v1/chat/completions' "$u"; fi
}

vscode_settings_default() {
    case "$(uname -s)" in
        Darwin*) printf '%s' "$HOME/Library/Application Support/Code/User/settings.json" ;;
        MINGW*|MSYS*|CYGWIN*) printf '%s' "${APPDATA:-$HOME/AppData/Roaming}/Code/User/settings.json" ;;
        *) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json" ;;
    esac
}
VSCODE_SETTINGS="${VSCODE_SETTINGS:-$(vscode_settings_default)}"

[[ -t 0 ]] || die "This script is interactive. Run it directly in a terminal."

# ---------- banner -----------------------------------------------------------
clear 2>/dev/null || true
printf '%b\n' "$CYAN"
printf '%s\n' '+--------------------------------------------------------------+'
printf '%s\n' '|     ant2oai / a2o + Claude Code setup (fixed edition)        |'
printf '%s\n' '+--------------------------------------------------------------+'
printf '%b\n' "$RESET"
printf '%s\n' 'Claude Code -> a2o (local) -> OpenAI-compatible API -> model'
printf '\n'

# ---------- requirements -----------------------------------------------------
section "Checking requirements"

PYTHON="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
[[ -n "$PYTHON" ]] || die "python3 is not installed."
command -v curl >/dev/null 2>&1 || die "curl is not installed."
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "Python 3.9 or newer is required."
"$PYTHON" -c 'import venv, ensurepip' >/dev/null 2>&1 \
    || die "Python venv is missing. On Debian/Ubuntu: sudo apt install python3-venv python3-pip"
success "Python: $PYTHON ($("$PYTHON" --version 2>&1))"

if command -v code >/dev/null 2>&1; then success "VS Code command detected."
else warn "'code' command not found; settings.json will still be edited directly."; fi

mkdir -p "$INSTALL_DIR"
success "Install directory: $INSTALL_DIR"

# ---------- provider ---------------------------------------------------------
section "Choose your OpenAI-compatible backend"

SAVED_UPSTREAM=""; SAVED_MODEL=""; SAVED_HOST=""; SAVED_PORT=""; SAVED_KEY=""; SAVED_PROVIDER=""
SAVED_THINKING=""; SAVED_THINKING_TOKENS=""
if [[ -f "$CONFIG_FILE" ]]; then
    # Read saved values once, in a subshell, so they cannot clobber script variables.
    eval "$(
        . "$CONFIG_FILE"
        printf 'SAVED_UPSTREAM=%q\n'        "${A2O_UPSTREAM:-}"
        printf 'SAVED_MODEL=%q\n'           "${A2O_MODEL:-}"
        printf 'SAVED_HOST=%q\n'            "${A2O_HOST:-}"
        printf 'SAVED_PORT=%q\n'            "${A2O_PORT:-}"
        printf 'SAVED_KEY=%q\n'             "${A2O_API_KEY:-}"
        printf 'SAVED_PROVIDER=%q\n'        "${A2O_PROVIDER_NAME:-}"
        printf 'SAVED_THINKING=%q\n'        "${A2O_THINKING:-}"
        printf 'SAVED_THINKING_TOKENS=%q\n' "${A2O_THINKING_TOKENS:-}"
    )"
fi

printf '\n  1) Dahl Inference\n'
printf '     %s\n     Default model: %s\n' "$DEFAULT_BASE_URL" "$DEFAULT_MODEL"
printf '\n  2) Custom OpenAI-compatible endpoint (you enter the URL and model)\n'
if [[ -n "$SAVED_UPSTREAM" ]]; then
    printf '\n  3) Reuse saved configuration\n     %s  (%s)\n' "$SAVED_UPSTREAM" "$SAVED_MODEL"
fi
printf '\n'

BASE_URL=""; MODEL=""; PROVIDER_NAME=""
while true; do
    printf 'Selection [1-3]: ' >&2
    read -r PROVIDER_CHOICE || die "Input closed."
    case "$PROVIDER_CHOICE" in
        1) BASE_URL="$DEFAULT_BASE_URL"; MODEL="$DEFAULT_MODEL"
           PROVIDER_NAME="Dahl Inference"; break ;;
        2) while true; do
               RAW_URL="$(prompt_required 'Base URL or full chat-completions URL')"
               if BASE_URL="$(normalize_upstream "$RAW_URL")"; then break; fi
               warn "The URL must start with http:// or https://"
           done
           info "Using upstream URL: $BASE_URL"
           MODEL="$(prompt_required 'Model name (exactly as the provider lists it)')"
           PROVIDER_NAME="Custom OpenAI-compatible provider"; break ;;
        3) if [[ -z "$SAVED_UPSTREAM" ]]; then warn "No saved configuration exists."; continue; fi
           BASE_URL="$SAVED_UPSTREAM"; MODEL="$SAVED_MODEL"
           PROVIDER_NAME="${SAVED_PROVIDER:-Saved configuration}"
           success "Saved configuration loaded."; break ;;
        *) warn "Please choose 1, 2, or 3." ;;
    esac
done

if [[ "$BASE_URL" == https://inference.dahl.global/* ]]; then
    info "Tip: Dahl rotates model IDs. Check https://inference.dahl.global/v1/models if the model is rejected."
fi

# ---------- API key ----------------------------------------------------------
section "API key"

API_KEY=""
printf '%s\n' 'a2o forwards the "Authorization: Bearer ..." header Claude Code sends, so the key'
printf '%s\n' 'must be sent as ANTHROPIC_AUTH_TOKEN. It is stored in config.env (600) and in'
printf '%s\n\n' 'your VS Code user settings.json (plain text).'
printf '  1) Enter an API key\n  2) No key (keyless endpoint)\n'
if [[ -n "$SAVED_KEY" ]]; then printf '  3) Keep the saved API key\n'; fi
printf '\n'

while true; do
    printf 'Selection [1-3]: ' >&2
    read -r KEY_CHOICE || die "Input closed."
    case "$KEY_CHOICE" in
        1) API_KEY="$(prompt_secret 'Enter API key (input hidden)')"
           if [[ -z "$API_KEY" ]]; then warn "Empty key."; continue; fi
           if [[ "$API_KEY" =~ [[:space:]] ]]; then warn "A key cannot contain spaces."; continue; fi
           if [[ "$API_KEY" == *\"* || "$API_KEY" == *\\* ]]; then warn "A key cannot contain quotes or backslashes."; continue; fi
           break ;;
        2) API_KEY=""; break ;;
        3) if [[ -z "$SAVED_KEY" ]]; then warn "There is no saved key."; continue; fi
           API_KEY="$SAVED_KEY"; success "Using the saved key."; break ;;
        *) warn "Please choose 1, 2, or 3." ;;
    esac
done

# ---------- local settings ---------------------------------------------------
section "Local a2o settings"

A2O_HOST="$(prompt_default 'Local a2o host' "${SAVED_HOST:-$A2O_HOST_DEFAULT}")"
A2O_PORT="$(prompt_default 'Local a2o port' "${SAVED_PORT:-$A2O_PORT_DEFAULT}")"
if [[ ! "$A2O_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$A2O_PORT < 1 || 10#$A2O_PORT > 65535 )); then
    die "Invalid port: $A2O_PORT"
fi
A2O_PORT=$(( 10#$A2O_PORT ))   # normalise "08" -> 8 (bash would read it as bad octal)
if [[ -z "$A2O_HOST" || "$A2O_HOST" =~ [[:space:]] ]]; then
    die "Invalid host: '$A2O_HOST'"
fi
A2O_DEBUG="0"
if confirm "Enable a2o --debug logging? (logs may contain your prompts)" N; then A2O_DEBUG="1"; fi

# ---------- thinking display -------------------------------------------------
section "Thinking display (Claude Code)"
printf '%s\n' 'a2o passes the model reasoning to Claude Code as "thinking" blocks. To actually see'
printf '%s\n' 'them, Claude Code needs alwaysThinkingEnabled + showThinkingSummaries (in'
printf '%s\n' "$CLAUDE_SETTINGS) and MAX_THINKING_TOKENS (in VS Code settings.json)."
THINKING="0"; THINKING_TOKENS=""
THINK_DEFAULT="Y"
if [[ "$SAVED_THINKING" == "0" ]]; then THINK_DEFAULT="N"; fi
if confirm "Configure these automatically? (backups are kept)" "$THINK_DEFAULT"; then
    THINKING="1"
    while true; do
        THINKING_TOKENS="$(prompt_default 'MAX_THINKING_TOKENS' "${SAVED_THINKING_TOKENS:-$DEFAULT_THINKING_TOKENS}")"
        if [[ "$THINKING_TOKENS" =~ ^[0-9]{1,7}$ ]] && (( 10#$THINKING_TOKENS > 0 )); then
            THINKING_TOKENS=$(( 10#$THINKING_TOKENS )); break
        fi
        warn "Enter a positive whole number."
    done
fi

port_busy() {   # port_busy HOST PORT  -> 0 if something is listening
    "$PYTHON" -c 'import socket,sys
h = sys.argv[1]
if h in ("0.0.0.0", "", "::"): h = "127.0.0.1"
s = socket.socket(); s.settimeout(1)
try: s.connect((h, int(sys.argv[2]))); sys.exit(0)
except OSError: sys.exit(1)' "$1" "$2" >/dev/null 2>&1
}

if port_busy "$A2O_HOST" "$A2O_PORT"; then
    warn "Something is already listening on port $A2O_PORT (an older a2o launcher?)."
    warn "Stop it before starting the new proxy. Setup can still continue."
fi

# ---------- upstream check ---------------------------------------------------
section "Checking the upstream (a few tokens are used)"

UP_BODY="$("$PYTHON" -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": "Reply with the single word: ready"}], "max_tokens": 16}))' "$MODEL")"
if [[ -n "$API_KEY" ]]; then
    UP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" \
        | curl -sS -K - --max-time 90 -o "$TMP/up.json" -w '%{http_code}' \
            -H 'Content-Type: application/json' -d "$UP_BODY" "$BASE_URL" 2>"$TMP/up.err")" || UP_CODE="000"
else
    UP_CODE="$(curl -sS --max-time 90 -o "$TMP/up.json" -w '%{http_code}' \
        -H 'Content-Type: application/json' -d "$UP_BODY" "$BASE_URL" 2>"$TMP/up.err")" || UP_CODE="000"
fi
case "$UP_CODE" in
    200) success "Upstream answered: the URL, key and model work." ;;
    401|403) warn "Upstream rejected the key (HTTP $UP_CODE)." ;;
    402) warn "Key accepted but no balance/tokens allocated (HTTP 402)." ;;
    400|404|422) warn "Upstream rejected the request (HTTP $UP_CODE): $(head -c 300 "$TMP/up.json")" ;;
    *) warn "Could not verify the upstream (HTTP $UP_CODE) $(head -c 200 "$TMP/up.err")" ;;
esac
if [[ "$UP_CODE" != "200" ]]; then
    confirm "Continue anyway?" N || { printf 'Setup cancelled.\n'; exit 0; }
fi

# ---------- summary ----------------------------------------------------------
section "Configuration summary"
printf '%-20s %s\n' "Provider:" "$PROVIDER_NAME"
printf '%-20s %s\n' "Upstream URL:" "$BASE_URL"
printf '%-20s %s\n' "Model:" "$MODEL"
printf '%-20s %s\n' "Local endpoint:" "http://$A2O_HOST:$A2O_PORT"
printf '%-20s %s\n' "API key:" "$([[ -n "$API_KEY" ]] && printf 'configured' || printf 'none')"
printf '%-20s %s\n' "Thinking display:" "$([[ "$THINKING" == "1" ]] && printf 'yes (MAX_THINKING_TOKENS=%s)' "$THINKING_TOKENS" || printf 'not configured')"
printf '%-20s %s\n' "a2o version:" "$A2O_VERSION (pinned)"
printf '%-20s %s\n' "Install directory:" "$INSTALL_DIR"
printf '%-20s %s\n' "VS Code settings:" "$VSCODE_SETTINGS"
printf '\n'
confirm "Continue with this configuration?" Y || { printf 'Setup cancelled.\n'; exit 0; }

# ---------- venv + install ---------------------------------------------------
section "Python environment"

if [[ ! -x "$VENV_BIN/python$EXE" ]]; then
    info "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
    success "Virtual environment created."
else
    success "Existing virtual environment found."
fi
# Use the venv's interpreter explicitly; no need to 'source activate'.
VENV_PYTHON="$VENV_BIN/python$EXE"

installed_version() { "$VENV_PYTHON" -m pip show ant2oai 2>/dev/null | sed -n 's/^Version: //p'; }

CUR_VER="$(installed_version || true)"
if [[ "$CUR_VER" == "$A2O_VERSION" ]]; then
    success "ant2oai $A2O_VERSION already installed."
else
    info "Installing ant2oai==$A2O_VERSION (currently: ${CUR_VER:-not installed})..."
    "$VENV_PYTHON" -m pip install --quiet --upgrade pip
    "$VENV_PYTHON" -m pip install --quiet "ant2oai==$A2O_VERSION"
    success "ant2oai $A2O_VERSION installed."
fi

# ---------- patch helper -----------------------------------------------------
section "Compatibility patches"

cat > "$PATCH_HELPER" <<'PYEOF'
#!/usr/bin/env python3
"""Check/apply the small a2o compatibility patches.  usage: a2o_patch.py status|apply

Each file is classified as:  patched | pristine | unknown
Only 'pristine' files are modified, and a pristine copy is kept as <file>.orig
"""
import importlib.util
import py_compile
import shutil
import sys
from pathlib import Path

MARK = "A2O-DSML-PATCH"
SCHEMA_MARK = "A2O-SCHEMA-PATCH"
# Bump this whenever the streaming patch changes: a file patched by an older script no longer
# carries it, so it is reported as "unknown" and the script offers a clean reinstall + re-patch.
STREAM_MARK = "A2O-DSML-PATCH-v2"


def pkg_dir():
    spec = importlib.util.find_spec("a2o")
    if spec is None or not spec.submodule_search_locations:
        sys.exit("a2o is not installed in this Python environment")
    return Path(list(spec.submodule_search_locations)[0])


# ---- parser.py: role="system" entries inside messages[] ----------------------
PARSER = [(
    '''    messages = _parse_messages(messages_raw)

    system = _parse_system(data.get("system"))
''',
    '''    # A2O-DSML-PATCH: Claude Code can put role="system" entries inside messages[].
    _extra_system = []
    _kept = []
    for _raw in messages_raw:
        if isinstance(_raw, dict) and _raw.get("role") == "system":
            _c = _raw.get("content")
            if isinstance(_c, str):
                if _c:
                    _extra_system.append({"type": "text", "text": _c})
            elif isinstance(_c, list):
                _extra_system.extend(b for b in _c if isinstance(b, dict))
        else:
            _kept.append(_raw)
    messages = _parse_messages(_kept)

    system = _parse_system(data.get("system"))
    if _extra_system:
        def _sys_text(s):
            if not s:
                return ""
            if isinstance(s, str):
                return s
            return "\\n\\n".join(b.text for b in s if getattr(b, "text", None))

        _joined = "\\n\\n".join(
            t for t in (_sys_text(system), _sys_text(_parse_system(_extra_system))) if t
        )
        system = _joined or None
''')]

# ---- request.py: no role="system" upstream -----------------------------------
REQUEST = [
    ('''    system_text = _build_system(req)
    if system_text:
        body["messages"] = body.get("messages", [])
        body["messages"].insert(0, {"role": "system", "content": system_text})
''',
     '''    system_text = _build_system(req)  # A2O-DSML-PATCH: merged into the first user message below
'''),
    ('''    if "messages" in body:
        body["messages"].extend(openai_messages)
    else:
        body["messages"] = openai_messages
''',
     '''    if "messages" in body:
        body["messages"].extend(openai_messages)
    else:
        body["messages"] = openai_messages

    # A2O-DSML-PATCH: some OpenAI-compatible servers (e.g. Dahl) reject role="system".
    # Fold the system prompt into the first user message instead.
    if system_text:
        _msgs = body["messages"]
        _first = next((m for m in _msgs if m.get("role") == "user"), None)
        if _first is None:
            _msgs.insert(0, {"role": "user", "content": system_text})
        elif isinstance(_first.get("content"), list):
            _first["content"].insert(0, {"type": "text", "text": system_text})
        else:
            _first["content"] = system_text + "\\n\\n" + (_first.get("content") or "")
'''),
]

# ---- response.py: DSML -> tool_use (non-streaming) ---------------------------
RESPONSE = [
    ('from a2o.models import AnthropicUsage\n',
     'from a2o.models import AnthropicUsage\nfrom a2o.converters.dsml import parse_dsml_tool_calls  # A2O-DSML-PATCH\n'),
    ('''        text = message.get("content")
        if text:
            content.append({"type": "text", "text": text})
''',
     '''        text = message.get("content")
        _dsml_calls = []  # A2O-DSML-PATCH: DeepSeek emits tool calls as DSML text
        if isinstance(text, str) and text:
            text, _dsml_calls = parse_dsml_tool_calls(text)
            if _dsml_calls:
                finish_reason = "tool_calls"
        if text:
            content.append({"type": "text", "text": text})
'''),
    ('            if not text and reasoning.strip():\n',
     '            if not text and not _dsml_calls and reasoning.strip():\n'),
    ('        tool_calls = message.get("tool_calls") or []\n',
     '        tool_calls = list(message.get("tool_calls") or []) + _dsml_calls\n'),
]

# ---- streaming.py: DSML -> tool_use (streaming) ------------------------------
STREAM_METHODS = '''    # A2O-DSML-PATCH: text is streamed live, but anything that looks like the start
    # of a DSML tool-call block is held back and converted to tool_use at finalize().
    def _emit_text_raw(self, events: list[str], text: str) -> None:
        if not text:
            return
        self._had_text = True
        idx = self._ensure_active_block(events, CONTENT_TEXT)
        data = _json_dumps(
            {
                "type": EVENT_CONTENT_BLOCK_DELTA,
                "index": idx,
                "delta": {"type": DELTA_TEXT, "text": text},
            }
        )
        events.append(_sse(EVENT_CONTENT_BLOCK_DELTA, data))

    def _emit_text(self, events: list[str], text: str) -> None:
        if self._in_dsml:
            self._dsml_buf += text
            return
        combined = self._hold + text
        pos = find_dsml_start(combined)
        if pos >= 0:
            self._emit_text_raw(events, combined[:pos])
            self._in_dsml = True
            self._dsml_buf = combined[pos:]
            self._hold = ""
            return
        keep = partial_start_len(combined)
        if keep:
            self._emit_text_raw(events, combined[:-keep])
            self._hold = combined[-keep:]
        else:
            self._emit_text_raw(events, combined)
            self._hold = ""

    def _finish_dsml(self, events: list[str]) -> None:
        if self._hold:
            held, self._hold = self._hold, ""
            self._emit_text_raw(events, held)
        if not self._in_dsml:
            return
        buf, self._dsml_buf = self._dsml_buf, ""
        self._in_dsml = False
        _rest, calls = parse_dsml_tool_calls(buf)
        if not calls:
            self._emit_text_raw(events, buf)
            return
        if _rest and _rest.strip():
            # A2O-DSML-PATCH-v2: text after the tool-call block cannot be placed safely after tool_use
            # blocks in the stream, so it is dropped; leave a trace instead of doing it silently.
            import logging
            logging.getLogger("a2o").warning(
                "A2O-DSML-PATCH: dropped %d chars of text that followed a DSML tool call", len(_rest.strip())
            )
        base = 1000 + len(self._tool_calls)
        for i, call in enumerate(calls):
            tc = dict(call)
            tc["index"] = base + i
            self._process_tool_call(events, tc)
        self.final_stop_reason = STOP_TOOL_USE

    def process_chunk(self, chunk: dict[str, Any]) -> list[str]:
'''

STREAMING = [
    ('from typing import Any\n',
     'from typing import Any\n\nfrom a2o.converters.dsml import find_dsml_start, parse_dsml_tool_calls, partial_start_len  # A2O-DSML-PATCH\n'),
    ('        self._thinking_buffer: list[str] = []\n',
     '        self._thinking_buffer: list[str] = []\n        self._hold = ""  # A2O-DSML-PATCH\n        self._in_dsml = False\n        self._dsml_buf = ""\n'),
    ('''        if delta.get("content"):
            self._had_text = True
            idx = self._ensure_active_block(events, CONTENT_TEXT)
            data = _json_dumps(
                {
                    "type": EVENT_CONTENT_BLOCK_DELTA,
                    "index": idx,
                    "delta": {"type": DELTA_TEXT, "text": delta["content"]},
                }
            )
            events.append(_sse(EVENT_CONTENT_BLOCK_DELTA, data))
''',
     '''        if delta.get("content"):
            self._emit_text(events, delta["content"])  # A2O-DSML-PATCH
'''),
    ('    def process_chunk(self, chunk: dict[str, Any]) -> list[str]:\n', STREAM_METHODS),
    ('''        events: list[str] = []

        self._close_active_block(events)

        # Stop remaining tool call blocks
''',
     '''        events: list[str] = []

        self._finish_dsml(events)  # A2O-DSML-PATCH

        self._close_active_block(events)

        # Stop remaining tool call blocks
'''),
]

# ---- request.py: strip unsupported regex "pattern" from tool schemas ---------
# Some tools (e.g. Claude Code's) ship JSON-schema patterns using lookaheads like (?!...),
# which certain OpenAI-compatible backends reject. Drop only those patterns.
SCHEMA = [
    ('def _tools_to_openai(tools)',
     '''def _sanitize_schema(value):  # A2O-SCHEMA-PATCH
    if isinstance(value, dict):
        return {
            k: _sanitize_schema(v)
            for k, v in value.items()
            if not (k == "pattern" and isinstance(v, str) and "(?" in v)
        }
    if isinstance(value, list):
        return [_sanitize_schema(v) for v in value]
    return value


def _tools_to_openai(tools)'''),
    ('params = dict(tool.input_schema)',
     'params = _sanitize_schema(tool.input_schema)  # A2O-SCHEMA-PATCH'),
]

# ---- streaming.py / response.py: accept the "reasoning" field ----------------
# a2o only reads "reasoning_content". Providers such as vLLM-based routers send the
# model's reasoning as "reasoning" instead, so it was dropped and Claude Code never
# received a thinking block. The "mark" for these two entries is the new expression
# itself, so a file that was hand-edited the same way is recognised as patched.
STREAM_REASONING = [(
    '        reasoning = additional.get("reasoning_content") or delta.get("reasoning_content")\n',
    '        reasoning = additional.get("reasoning_content") or delta.get("reasoning_content") or delta.get("reasoning")  # A2O-REASONING-PATCH\n')]

RESPONSE_REASONING = [(
    '        reasoning = additional.get("reasoning_content") or message.get("reasoning_content")\n',
    '        reasoning = additional.get("reasoning_content") or message.get("reasoning_content") or message.get("reasoning")  # A2O-REASONING-PATCH\n')]

FILES = {
    "parser": ("converters/parser.py", PARSER, MARK),
    "request": ("converters/request.py", REQUEST, MARK),
    "schema": ("converters/request.py", SCHEMA, SCHEMA_MARK),
    "response": ("converters/response.py", RESPONSE, MARK),
    "streaming": ("converters/streaming.py", STREAMING, STREAM_MARK),
    "stream_reasoning": ("converters/streaming.py", STREAM_REASONING, 'delta.get("reasoning")'),
    "response_reasoning": ("converters/response.py", RESPONSE_REASONING, 'message.get("reasoning")'),
}

DSML_SOURCE = r'''"""Parse DeepSeek DSML tool calls into OpenAI-style tool calls.  A2O-DSML-PATCH"""

from __future__ import annotations

import json
import re
import uuid
from typing import Any

P = "\uff5c"  # the full-width bar used by DeepSeek special tokens

_START_TAGS = (f"<{P}DSML{P}tool_calls>", f"<{P}DSML{P}function_calls>")
_END_RE = re.compile(rf"</{P}DSML{P}(?:tool|function)_calls>")
_INVOKE_RE = re.compile(
    rf'<{P}DSML{P}invoke\s+name="([^"]+)">(.*?)</{P}DSML{P}invoke>', re.DOTALL
)
_PARAM_RE = re.compile(
    rf'<{P}DSML{P}parameter\s+name="([^"]+)"(?:\s+string="(true|false)")?>(.*?)</{P}DSML{P}parameter>',
    re.DOTALL,
)


def find_dsml_start(text: str) -> int:
    hits = [i for i in (text.find(t) for t in _START_TAGS) if i >= 0]
    return min(hits) if hits else -1


def partial_start_len(text: str) -> int:
    """Length of the longest tail of text that could be the beginning of a start tag."""
    longest = max(len(t) for t in _START_TAGS) - 1
    for k in range(min(len(text), longest), 0, -1):
        tail = text[-k:]
        if any(t.startswith(tail) for t in _START_TAGS):
            return k
    return 0


def _parse_block(block: str) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []
    for inv in _INVOKE_RE.finditer(block):
        name, body = inv.group(1), inv.group(2)
        args: dict[str, Any] = {}
        for pm in _PARAM_RE.finditer(body):
            pname, is_str, raw = pm.group(1), pm.group(2), pm.group(3)
            if is_str == "true":
                value: Any = raw
            else:
                try:
                    value = json.loads(raw)
                except json.JSONDecodeError:
                    value = raw
            args[pname] = value
        calls.append(
            {
                "id": f"toolu_{uuid.uuid4().hex[:24]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(args, ensure_ascii=True, separators=(",", ":")),
                },
            }
        )
    return calls


def parse_dsml_tool_calls(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Return (remaining_text, OpenAI-style tool_calls). Handles several blocks in one
    message. Incomplete or unparseable blocks are left as text."""
    if not text:
        return text, []
    remaining = text
    calls: list[dict[str, Any]] = []
    while True:
        start = find_dsml_start(remaining)
        if start < 0:
            break
        end_m = _END_RE.search(remaining, start)
        if end_m is None:
            break
        found = _parse_block(remaining[start:end_m.end()])
        if not found:
            break
        calls.extend(found)
        remaining = remaining[:start] + remaining[end_m.end():]
    if not calls:
        return text, []
    return remaining.strip(), calls
'''


def state(path, pairs, mark):
    text = path.read_text(encoding="utf-8")
    if mark in text:
        return "patched"
    if all(old in text for old, _ in pairs):
        return "pristine"
    return "unknown"


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    base = pkg_dir()
    states = {n: state(base / rel, pairs, mark) for n, (rel, pairs, mark) in FILES.items()}

    if cmd == "status":
        for n, s in states.items():
            print(f"{n}={s}")
        return 0

    if cmd != "apply":
        sys.exit("usage: a2o_patch.py status|apply")

    unknown = [n for n, s in states.items() if s == "unknown"]
    if unknown:
        print("UNKNOWN: " + ", ".join(unknown))
        return 3

    # Snapshot everything we may touch, so a failure restores the exact pre-run state
    # (not just the pristine copy, which would also throw away earlier patches).
    snapshots = {}
    for rel in {rel for rel, _p, _m in FILES.values()}:
        snapshots[base / rel] = (base / rel).read_text(encoding="utf-8")
    dsml_path = base / "converters" / "dsml.py"
    dsml_before = dsml_path.read_text(encoding="utf-8") if dsml_path.exists() else None

    # Refresh the *.orig copy only for files that are completely pristine right now, so a
    # stale copy from another a2o version can never be restored over a newer file.
    by_file = {}
    for n, (rel, _p, _m) in FILES.items():
        by_file.setdefault(rel, []).append(n)
    for rel, names in by_file.items():
        if all(states[n] == "pristine" for n in names):
            path = base / rel
            shutil.copy2(path, path.with_name(path.name + ".orig"))

    try:
        for n, (rel, pairs, _mark) in FILES.items():
            path = base / rel
            if states[n] != "pristine":
                print(f"{n}: already patched")
                continue
            text = path.read_text(encoding="utf-8")
            for old, new in pairs:
                if text.count(old) != 1:
                    raise RuntimeError(f"{n}: expected block found {text.count(old)} times")
                text = text.replace(old, new, 1)
            path.write_text(text, encoding="utf-8")
            print(f"{n}: patched")
        dsml_path.write_text(DSML_SOURCE, encoding="utf-8")
        print("dsml: written")
        for n, (rel, _p, _m) in FILES.items():
            py_compile.compile(str(base / rel), doraise=True)
        py_compile.compile(str(dsml_path), doraise=True)
    except Exception as exc:  # put every file back exactly as it was before this run
        for path, text in snapshots.items():
            path.write_text(text, encoding="utf-8")
        if dsml_before is None:
            dsml_path.unlink(missing_ok=True)
        else:
            dsml_path.write_text(dsml_before, encoding="utf-8")
        print(f"FAILED: {exc} (files restored to their state before this run)")
        return 4
    return 0


sys.exit(main())
PYEOF
chmod 600 "$PATCH_HELPER"

# Settings helper: merges a2o/Claude Code settings into JSON files (tolerates comments, keeps the
# token out of argv). Written here so the offline tests can exercise it too.
cat > "$SETTINGS_HELPER" <<'SETPY'
#!/usr/bin/env python3
"""Merge a2o / Claude Code settings into JSON settings files.

usage:
  a2o_settings.py vscode SETTINGS_JSON BASE_URL MODEL [THINKING_TOKENS] [--allow-jsonc]
  a2o_settings.py claude SETTINGS_JSON [--allow-jsonc]

The API token is read from the A2O_SETTINGS_TOKEN environment variable (never from argv,
so it does not show up in `ps`).

Exit codes: 0 ok | 3 cannot edit safely (file left untouched)
            4 file has comments / trailing commas and --allow-jsonc was not given
"""
import json
import os
import sys
import tempfile
from pathlib import Path


def _strip_comments(text):
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _strip_trailing_commas(text):
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
        elif c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_jsonc(text):
    return _strip_trailing_commas(_strip_comments(text))


def load(path, allow_jsonc):
    """Return (settings_dict, had_jsonc_features)."""
    text = path.read_text(encoding="utf-8-sig") if path.exists() else ""
    if not text.strip():
        return {}, False
    try:
        data, jsonc = json.loads(text), False
    except json.JSONDecodeError:
        try:
            data, jsonc = json.loads(strip_jsonc(text)), True
        except json.JSONDecodeError as exc:
            print("%s is not valid JSON, even ignoring comments: %s" % (path, exc))
            sys.exit(3)
        if not allow_jsonc:
            print("%s has comments or trailing commas; editing it would drop the comments" % path)
            sys.exit(4)
    if not isinstance(data, dict):
        print("%s must contain a JSON object" % path)
        sys.exit(3)
    return data, jsonc


def save(path, settings):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8")
    try:
        json.dump(settings, tmp, indent=2, ensure_ascii=False)
        tmp.write("\n")
        tmp.close()
        os.chmod(tmp.name, 0o600)  # the file holds an API key
        os.replace(tmp.name, path)
    except BaseException:
        tmp.close()
        if os.path.exists(tmp.name):
            os.unlink(tmp.name)
        raise


def cmd_vscode(path, base_url, model, think_tokens, allow_jsonc):
    token = os.environ.get("A2O_SETTINGS_TOKEN", "")
    if not token:
        print("A2O_SETTINGS_TOKEN is not set")
        sys.exit(3)
    settings, jsonc = load(path, allow_jsonc)
    key = "claudeCode.environmentVariables"
    existing = settings.get(key, [])
    if not isinstance(existing, list):
        print("%s exists but is not an array; refusing to overwrite it" % key)
        sys.exit(3)

    managed = {"ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"}
    if think_tokens:
        managed.add("MAX_THINKING_TOKENS")
    removed = [e["name"] for e in existing if isinstance(e, dict) and e.get("name") in managed]
    kept = [e for e in existing if not (isinstance(e, dict) and e.get("name") in managed)]
    kept += [
        {"name": "ANTHROPIC_BASE_URL", "value": base_url},
        {"name": "ANTHROPIC_AUTH_TOKEN", "value": token},  # a2o forwards Authorization: Bearer <this>
        {"name": "ANTHROPIC_MODEL", "value": model},
    ]
    if think_tokens:
        kept.append({"name": "MAX_THINKING_TOKENS", "value": str(think_tokens)})
    settings[key] = kept
    if "claudeCode.selectedModel" in settings:
        print("NOTE: claudeCode.selectedModel is set and may override ANTHROPIC_MODEL; consider removing it")
    save(path, settings)
    if jsonc:
        print("NOTE: comments / trailing commas were dropped (your backup keeps them)")
    if removed:
        print("Replaced existing entries: " + ", ".join(removed))
    print("OK")


def cmd_claude(path, allow_jsonc):
    settings, jsonc = load(path, allow_jsonc)
    settings["alwaysThinkingEnabled"] = True
    settings["showThinkingSummaries"] = True
    save(path, settings)
    if jsonc:
        print("NOTE: comments / trailing commas were dropped (your backup keeps them)")
    print("OK")


def main(argv):
    allow = "--allow-jsonc" in argv
    args = [a for a in argv[1:] if a != "--allow-jsonc"]
    if len(args) >= 4 and args[0] == "vscode":
        tokens = args[4] if len(args) > 4 else ""
        cmd_vscode(Path(args[1]), args[2], args[3], tokens, allow)
    elif len(args) == 2 and args[0] == "claude":
        cmd_claude(Path(args[1]), allow)
    else:
        sys.exit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
SETPY
chmod 600 "$SETTINGS_HELPER"

info "Checking which a2o files are already patched..."
PATCH_STATUS="$("$VENV_PYTHON" "$PATCH_HELPER" status)"
printf '%s\n' "$PATCH_STATUS" | sed 's/^/  /'

if printf '%s\n' "$PATCH_STATUS" | grep -q '=unknown'; then
    warn "Some a2o files are neither pristine nor patched by this script"
    warn "(for example, edited by hand in an earlier attempt)."
    if confirm "Reinstall a2o $A2O_VERSION cleanly so the patches can be applied?" Y; then
        "$VENV_PYTHON" -m pip install --quiet --force-reinstall --no-deps "ant2oai==$A2O_VERSION"
        success "ant2oai reinstalled."
    else
        die "Cannot continue with unrecognized a2o files."
    fi
fi

PATCH_RC=0
"$VENV_PYTHON" "$PATCH_HELPER" apply || PATCH_RC=$?
case "$PATCH_RC" in
    0) success "All patches are in place." ;;
    3) die "a2o files still look different from version $A2O_VERSION. Try: A2O_VERSION=<other> or reinstall." ;;
    *) die "Patching failed; files were restored to how they were before this run. See the message above." ;;
esac

# ---------- offline tests ----------------------------------------------------
section "Tests"

info "Test 1/10: system messages inside messages[] are extracted (all system shapes)"
"$VENV_PYTHON" - <<'PY'
from a2o.converters.parser import parse_anthropic_request

def run(top, extra_content):
    data = {"model": "t", "max_tokens": 50,
            "messages": [{"role": "system", "content": extra_content},
                         {"role": "user", "content": "Hello"}]}
    if top is not None:
        data["system"] = top
    req = parse_anthropic_request(data)
    assert [m.role for m in req.messages] == ["user"], req.messages
    return req.system

s = run(None, "EXTRA")
assert s and "EXTRA" in str(s)
s = run("TOP", "EXTRA")                                   # str + str
assert "TOP" in s and "EXTRA" in s, s
s = run([{"type": "text", "text": "TOP"}], "EXTRA")       # list + str (was silently dropped before)
assert "TOP" in s and "EXTRA" in s, s
s = run("TOP", [{"type": "text", "text": "EXTRA"}])       # str + list
assert "TOP" in s and "EXTRA" in s, s
print("PASS")
PY

info "Test 2/10: DSML parser"
"$VENV_PYTHON" - <<'PY'
import json
from a2o.converters.dsml import parse_dsml_tool_calls, partial_start_len, find_dsml_start
P = "\uff5c"
s = (f"<{P}DSML{P}tool_calls>\n<{P}DSML{P}invoke name=\"read_file\">\n"
     f"<{P}DSML{P}parameter name=\"file_path\" string=\"true\">/tmp/test.txt</{P}DSML{P}parameter>\n"
     f"<{P}DSML{P}parameter name=\"offset\">3</{P}DSML{P}parameter>\n"
     f"</{P}DSML{P}invoke>\n</{P}DSML{P}tool_calls>")
text, calls = parse_dsml_tool_calls("Let me look.\n" + s)
assert text == "Let me look." and len(calls) == 1
a = json.loads(calls[0]["function"]["arguments"])
assert calls[0]["function"]["name"] == "read_file" and a == {"file_path": "/tmp/test.txt", "offset": 3}, a
assert parse_dsml_tool_calls(s[:-10])[1] == []            # incomplete block stays text
assert parse_dsml_tool_calls("plain")[1] == []
t2, c2 = parse_dsml_tool_calls("A\n" + s + "\nmid\n" + s)       # several blocks in one message
assert len(c2) == 2 and t2.startswith("A") and "DSML" not in t2, (t2, c2)
assert partial_start_len("abc<" + P + "DS") == 4 and partial_start_len("abc") == 0
print("PASS")
PY

info "Test 3/10: non-streaming DSML -> Anthropic tool_use"
"$VENV_PYTHON" - <<'PY'
from a2o.converters.response import convert_openai_to_anthropic
P = "\uff5c"
dsml = (f"<{P}DSML{P}tool_calls><{P}DSML{P}invoke name=\"read_file\">"
        f"<{P}DSML{P}parameter name=\"file_path\" string=\"true\">/tmp/x</{P}DSML{P}parameter>"
        f"</{P}DSML{P}invoke></{P}DSML{P}tool_calls>")
r = convert_openai_to_anthropic({"id": "x", "model": "m", "choices": [
    {"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": dsml}}]})
assert r["stop_reason"] == "tool_use", r
assert [b["type"] for b in r["content"]] == ["tool_use"], r["content"]
assert r["content"][0]["input"] == {"file_path": "/tmp/x"}
r = convert_openai_to_anthropic({"id": "x", "model": "m", "choices": [
    {"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "hello"}}]})
assert r["stop_reason"] == "end_turn" and r["content"][0]["text"] == "hello"
print("PASS")
PY

info "Test 4/10: request conversion never sends role=system upstream"
"$VENV_PYTHON" - <<'PY'
from a2o.converters.parser import parse_anthropic_request
from a2o.converters.request import convert_anthropic_to_openai
req = parse_anthropic_request({"model": "t", "max_tokens": 50,
    "system": [{"type": "text", "text": "SYS"}],
    "messages": [{"role": "system", "content": "EXTRA"}, {"role": "user", "content": "Hello"}]})
body = convert_anthropic_to_openai(req)
roles = [m["role"] for m in body["messages"]]
assert "system" not in roles, roles
first = body["messages"][0]["content"]
assert first.startswith("SYS") and "EXTRA" in first and first.endswith("Hello"), first
req = parse_anthropic_request({"model": "t", "max_tokens": 50, "messages": [{"role": "user", "content": "Hi"}]})
assert convert_anthropic_to_openai(req)["messages"] == [{"role": "user", "content": "Hi"}]
print("PASS")
PY

info "Test 5/10: streaming DSML -> tool_use (split across chunks)"
"$VENV_PYTHON" - <<'PY'
import json
import logging
from a2o.converters.streaming import convert_openai_stream_to_anthropic_sse
logged = []
class _Capture(logging.Handler):
    def emit(self, record): logged.append(record.getMessage())
logging.getLogger("a2o").addHandler(_Capture())
P = "\uff5c"
dsml = (f"<{P}DSML{P}tool_calls><{P}DSML{P}invoke name=\"read_file\">"
        f"<{P}DSML{P}parameter name=\"file_path\" string=\"true\">/tmp/x</{P}DSML{P}parameter>"
        f"</{P}DSML{P}invoke></{P}DSML{P}tool_calls>")
full = "Reading it now. " + dsml
pieces = [full[i:i + 7] for i in range(0, len(full), 7)]          # cut through the tags
chunks = [{"model": "m", "choices": [{"index": 0, "delta": {"content": p}, "finish_reason": None}]} for p in pieces]
chunks.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
events = convert_openai_stream_to_anthropic_sse(chunks, "m")
datas = [json.loads(e.split("data: ", 1)[1]) for e in events]
text = "".join(d["delta"]["text"] for d in datas if d.get("delta", {}).get("type") == "text_delta")
assert text == "Reading it now. ", repr(text)
assert "DSML" not in text
starts = [d for d in datas if d["type"] == "content_block_start" and d["content_block"]["type"] == "tool_use"]
assert len(starts) == 1 and starts[0]["content_block"]["name"] == "read_file"
args = "".join(d["delta"]["partial_json"] for d in datas if d.get("delta", {}).get("type") == "input_json_delta")
assert json.loads(args) == {"file_path": "/tmp/x"}, args
assert [d for d in datas if d["type"] == "message_delta"][0]["delta"]["stop_reason"] == "tool_use"
assert datas[-1]["type"] == "message_stop"
# text AFTER the block is dropped (with a log line) but must not break the stream
full2 = "Reading it now. " + dsml + " trailing words"
ch2 = [{"model": "m", "choices": [{"index": 0, "delta": {"content": full2[i:i + 7]}, "finish_reason": None}]} for i in range(0, len(full2), 7)]
ch2.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
d3 = [json.loads(e.split("data: ", 1)[1]) for e in convert_openai_stream_to_anthropic_sse(ch2, "m")]
assert any(d["type"] == "content_block_start" and d["content_block"]["type"] == "tool_use" for d in d3)
assert "DSML" not in "".join(d["delta"]["text"] for d in d3 if d.get("delta", {}).get("type") == "text_delta")
assert any("dropped" in m for m in logged), logged          # ...and it says so in the log
# plain streaming text must be unaffected
plain = [{"model": "m", "choices": [{"index": 0, "delta": {"content": c}, "finish_reason": None}]} for c in ["Hel", "lo <", "b>ok"]]
plain.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
d2 = [json.loads(e.split("data: ", 1)[1]) for e in convert_openai_stream_to_anthropic_sse(plain, "m")]
assert "".join(d["delta"]["text"] for d in d2 if d.get("delta", {}).get("type") == "text_delta") == "Hello <b>ok"
assert [d for d in d2 if d["type"] == "message_delta"][0]["delta"]["stop_reason"] == "end_turn"
print("PASS")
PY
info "Test 6/10: tool schemas lose lookahead patterns but keep everything else"
"$VENV_PYTHON" - <<'PY'
from a2o.converters.parser import parse_anthropic_request
from a2o.converters.request import convert_anthropic_to_openai
schema = {"type": "object", "properties": {
    "bad":  {"type": "string", "pattern": "^(?!-)[a-z]+$"},
    "good": {"type": "string", "pattern": "^[a-z]+$"},
    "pattern": {"type": "string"},                       # a property NAMED pattern
    "nested": {"anyOf": [{"type": "string", "pattern": "(?<=x)y"}, {"type": "integer"}]}}}
req = parse_anthropic_request({"model": "t", "max_tokens": 50,
    "tools": [{"name": "t1", "description": "d", "input_schema": schema}],
    "messages": [{"role": "user", "content": "Hi"}]})
props = convert_anthropic_to_openai(req)["tools"][0]["function"]["parameters"]["properties"]
assert "pattern" not in props["bad"], props["bad"]
assert props["good"]["pattern"] == "^[a-z]+$", props["good"]
assert props["pattern"] == {"type": "string"}, props["pattern"]
assert "pattern" not in props["nested"]["anyOf"][0], props["nested"]
assert schema["properties"]["bad"]["pattern"] == "^(?!-)[a-z]+$"   # input not mutated
print("PASS")
PY
info "Test 7/10: streaming reasoning (field name 'reasoning') -> thinking block, then text"
"$VENV_PYTHON" - <<'PY'
import json
from a2o.converters.streaming import convert_openai_stream_to_anthropic_sse

def run(field):
    chunks = [{"model": "m", "choices": [{"index": 0, "delta": {"content": "", "role": "assistant"}, "finish_reason": None}]}]
    for piece in ["The user", " asks 17*23."]:
        chunks.append({"model": "m", "choices": [{"index": 0, "delta": {field: piece}, "finish_reason": None}]})
    chunks.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": None}]})   # empty delta in between
    for piece in ["391"]:
        chunks.append({"model": "m", "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
    chunks.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
    events = convert_openai_stream_to_anthropic_sse(chunks, "m")
    return [json.loads(e.split("data: ", 1)[1]) for e in events]

for field in ("reasoning", "reasoning_content"):          # new name AND the original name
    datas = run(field)
    starts = [d["content_block"]["type"] for d in datas if d["type"] == "content_block_start"]
    assert starts == ["thinking", "text"], (field, starts)
    think = "".join(d["delta"]["thinking"] for d in datas if d.get("delta", {}).get("type") == "thinking_delta")
    text = "".join(d["delta"]["text"] for d in datas if d.get("delta", {}).get("type") == "text_delta")
    assert think == "The user asks 17*23.", (field, think)
    assert text == "391", (field, text)
    assert [d for d in datas if d["type"] == "message_delta"][0]["delta"]["stop_reason"] == "end_turn"
print("PASS")
PY

info "Test 8/10: non-streaming reasoning (field name 'reasoning') -> thinking block"
"$VENV_PYTHON" - <<'PY'
from a2o.converters.response import convert_openai_to_anthropic

def conv(msg):
    return convert_openai_to_anthropic({"id": "x", "model": "m", "choices": [
        {"index": 0, "finish_reason": "stop", "message": dict({"role": "assistant"}, **msg)}]})

for field in ("reasoning", "reasoning_content"):
    r = conv({"content": "391", field: "17*23 = 391"})
    kinds = sorted(b["type"] for b in r["content"])
    assert kinds == ["text", "thinking"], (field, r["content"])
    assert [b["thinking"] for b in r["content"] if b["type"] == "thinking"] == ["17*23 = 391"]
    assert [b["text"] for b in r["content"] if b["type"] == "text"] == ["391"]
r = conv({"content": "hello"})                                     # no reasoning: unchanged
assert [b["type"] for b in r["content"]] == ["text"], r["content"]
print("PASS")
PY
info "Test 9/10: a follow-up turn with a thinking block in history converts cleanly"
"$VENV_PYTHON" - <<'PY'
import json
from a2o.converters.parser import parse_anthropic_request
from a2o.converters.request import convert_anthropic_to_openai
req = parse_anthropic_request({"model": "t", "max_tokens": 50, "messages": [
    {"role": "user", "content": "What is 17*23?"},
    {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "SECRET-REASONING", "signature": "sig"},
        {"type": "text", "text": "391"}]},
    {"role": "user", "content": "Now double it."}]})
msgs = convert_anthropic_to_openai(req)["messages"]
asst = [m for m in msgs if m["role"] == "assistant"][0]
assert asst["content"] == "391", asst                      # reasoning must not leak into visible text
assert '"type": "thinking"' not in json.dumps(msgs), msgs   # no Anthropic-only block types upstream
extra = sorted(set(asst) - {"role", "content"})
print("PASS" + (" (note: assistant history also carries %s upstream; the live smoke test checks your provider accepts that)" % extra if extra else ""))
PY

info "Test 10/10: settings helper (comments, idempotent, token via env, strings left intact)"
"$VENV_PYTHON" - "$SETTINGS_HELPER" <<'PY'
import json, os, subprocess, sys, tempfile
helper = sys.argv[1]
d = tempfile.mkdtemp()
URL = "http://127.0.0.1:3578"

def run(*args, token="sekret-token"):
    env = dict(os.environ)
    env.pop("A2O_SETTINGS_TOKEN", None)
    if token:
        env["A2O_SETTINGS_TOKEN"] = token
    r = subprocess.run([sys.executable, helper, *args], env=env, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

vs = os.path.join(d, "settings.json")
open(vs, "w").write('{\n  // my editor\n  "editor.fontSize": 14, /* inline */\n  "claudeCode.environmentVariables": [\n'
                    '    {"name": "KEEP_ME", "value": "1"},\n    {"name": "ANTHROPIC_MODEL", "value": "old"},\n  ],\n}\n')
rc, out = run("vscode", vs, URL, "m1", "16000")
assert rc == 4, (rc, out)                                   # comments: needs consent
assert "// my editor" in open(vs).read()                    # ...and the file is untouched without it
assert "sekret-token" not in out
rc, out = run("vscode", vs, URL, "m1", "16000", "--allow-jsonc")
assert rc == 0, (rc, out)
cfg = json.load(open(vs))
env = {e["name"]: e["value"] for e in cfg["claudeCode.environmentVariables"]}
assert env["KEEP_ME"] == "1" and env["ANTHROPIC_MODEL"] == "m1" and env["MAX_THINKING_TOKENS"] == "16000", env
assert env["ANTHROPIC_AUTH_TOKEN"] == "sekret-token" and env["ANTHROPIC_BASE_URL"] == URL, env
assert cfg["editor.fontSize"] == 14
rc, out = run("vscode", vs, URL, "m2")                     # re-run: no duplicates, thinking entry left alone
assert rc == 0, (rc, out)
names = [e["name"] for e in json.load(open(vs))["claudeCode.environmentVariables"]]
assert len(names) == len(set(names)) and "MAX_THINKING_TOKENS" in names, names
assert run("vscode", vs, URL, "m2", token=None)[0] == 3     # token is mandatory
if os.name == "posix":
    assert (os.stat(vs).st_mode & 0o777) == 0o600           # the file holds a key
cl = os.path.join(d, "claude.json")
open(cl, "w").write('{"url": "http://x//y", "t": "a,]", // c\n "k": 1,}\n')   # // and ,] inside strings
rc, out = run("claude", cl, "--allow-jsonc")
c = json.load(open(cl))
assert rc == 0 and c["url"] == "http://x//y" and c["t"] == "a,]" and c["k"] == 1, (rc, out, c)
assert c["alwaysThinkingEnabled"] is True and c["showThinkingSummaries"] is True
bad = os.path.join(d, "bad.json")
open(bad, "w").write("{ nope")
assert run("claude", bad, "--allow-jsonc")[0] == 3 and open(bad).read() == "{ nope"
print("PASS")
PY
success "All 10 offline tests passed."

# ---------- save configuration -----------------------------------------------
section "Saving configuration"

( umask 077
cat > "$CONFIG_FILE" <<EOF
# ant2oai / a2o configuration (generated $(date)). Keep permissions at 600.
A2O_PROVIDER_NAME=$(printf '%q' "$PROVIDER_NAME")
A2O_UPSTREAM=$(printf '%q' "$BASE_URL")
A2O_MODEL=$(printf '%q' "$MODEL")
A2O_HOST=$(printf '%q' "$A2O_HOST")
A2O_PORT=$(printf '%q' "$A2O_PORT")
A2O_API_KEY=$(printf '%q' "$API_KEY")
A2O_DEBUG=$(printf '%q' "$A2O_DEBUG")
A2O_THINKING=$(printf '%q' "$THINKING")
A2O_THINKING_TOKENS=$(printf '%q' "$THINKING_TOKENS")
EOF
)
chmod 600 "$CONFIG_FILE"
success "Saved $CONFIG_FILE (permissions 600)"

# ---------- launcher ---------------------------------------------------------
section "Creating launcher"

cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
# Starts the local a2o proxy using ~/ant2oia/config.env.   Usage: start-a2o.sh
set -Eeuo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$INSTALL_DIR/config.env"
A2O_BIN="$INSTALL_DIR/.venv/bin/a2o"
[[ -x "$A2O_BIN" ]] || A2O_BIN="$INSTALL_DIR/.venv/Scripts/a2o.exe"   # Windows (Git Bash)

[[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] Missing $CONFIG_FILE"; exit 1; }
[[ -x "$A2O_BIN" ]] || { echo "[ERROR] a2o not found: $A2O_BIN"; exit 1; }

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${A2O_UPSTREAM:?A2O_UPSTREAM is not configured}"
: "${A2O_MODEL:?A2O_MODEL is not configured}"
A2O_HOST="${A2O_HOST:-127.0.0.1}"
A2O_PORT="${A2O_PORT:-3578}"

echo
echo "Provider : ${A2O_PROVIDER_NAME:-Custom}"
echo "Upstream : $A2O_UPSTREAM"
echo "Model    : $A2O_MODEL"
echo "Local    : http://$A2O_HOST:$A2O_PORT"
echo "Stop with Ctrl+C."
echo

args=(--host "$A2O_HOST" --port "$A2O_PORT" --upstream "$A2O_UPSTREAM" --model "$A2O_MODEL")
if [[ "${A2O_DEBUG:-0}" == "1" ]]; then args+=(--debug); fi

# The API key is NOT given to a2o here: a2o forwards the Authorization header
# that Claude Code sends (ANTHROPIC_AUTH_TOKEN in VS Code settings).
exec "$A2O_BIN" "${args[@]}"
EOF
chmod +x "$LAUNCHER"
success "Launcher: $LAUNCHER"

# ---------- VS Code settings -------------------------------------------------
section "Configuring VS Code Claude Code"

TOKEN_VALUE="${API_KEY:-$PLACEHOLDER_TOKEN}"

backup_file() {   # backup_file FILE : copy to FILE.bak.<timestamp> (mode 600), keep the newest N
    local f="$1" bak="$1.bak.$TIMESTAMP" old=""
    [[ -f "$f" ]] || return 0
    cp "$f" "$bak"
    chmod 600 "$bak"
    old="$(ls -1t "$f".bak.* 2>/dev/null | tail -n +$(( BACKUPS_KEEP + 1 )) || true)"
    if [[ -n "$old" ]]; then
        printf '%s\n' "$old" | while IFS= read -r b; do rm -f -- "$b"; done
    fi
    success "Backed up $f -> $(basename "$bak") (keeping the newest $BACKUPS_KEEP)"
}

SETTINGS_OUT=""
run_settings_helper() {   # run_settings_helper LABEL ARGS... ; output in $SETTINGS_OUT, returns helper's code
    local label="$1" rc=0; shift
    SETTINGS_OUT="$(A2O_SETTINGS_TOKEN="$TOKEN_VALUE" "$VENV_PYTHON" "$SETTINGS_HELPER" "$@" 2>&1)" || rc=$?
    if [[ "$rc" -eq 4 ]]; then
        warn "$label has comments or trailing commas. Editing it automatically drops them (the backup keeps them)."
        if confirm "Edit it anyway?" N; then
            rc=0
            SETTINGS_OUT="$(A2O_SETTINGS_TOKEN="$TOKEN_VALUE" "$VENV_PYTHON" "$SETTINGS_HELPER" "$@" --allow-jsonc 2>&1)" || rc=$?
        fi
    fi
    return "$rc"
}

print_manual_snippet() {
    local snippet_token="$PLACEHOLDER_TOKEN" think_line=""
    if [[ -n "$API_KEY" ]]; then snippet_token="<your API key>"; fi
    if [[ "$THINKING" == "1" ]]; then
        think_line=",
    { \"name\": \"MAX_THINKING_TOKENS\", \"value\": \"$THINKING_TOKENS\" }"
    fi
    warn "Add this to your VS Code user settings.json by hand:"
    cat <<EOF

"claudeCode.environmentVariables": [
    { "name": "ANTHROPIC_BASE_URL", "value": "http://$A2O_HOST:$A2O_PORT" },
    { "name": "ANTHROPIC_AUTH_TOKEN", "value": "$snippet_token" },
    { "name": "ANTHROPIC_MODEL", "value": "$MODEL" }$think_line
]

EOF
}

mkdir -p "$(dirname "$VSCODE_SETTINGS")"
backup_file "$VSCODE_SETTINGS"
if run_settings_helper "VS Code settings.json" vscode "$VSCODE_SETTINGS" "http://$A2O_HOST:$A2O_PORT" "$MODEL" "${THINKING_TOKENS:-}"; then
    printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /'
    success "Claude Code environment variables configured."
else
    printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /' >&2
    warn "Could not edit settings.json automatically (it was not changed)."
    print_manual_snippet
fi

if [[ "$THINKING" == "1" ]]; then
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    backup_file "$CLAUDE_SETTINGS"
    if run_settings_helper "$CLAUDE_SETTINGS" claude "$CLAUDE_SETTINGS"; then
        printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /'
        success "Thinking display enabled in $CLAUDE_SETTINGS"
    else
        printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /' >&2
        warn "Could not edit $CLAUDE_SETTINGS automatically (it was not changed). Add by hand:"
        printf '\n  "alwaysThinkingEnabled": true,\n  "showThinkingSummaries": true\n\n'
    fi
fi

# ---------- optional live smoke test -----------------------------------------
section "Live smoke test (optional)"

if confirm "Start a2o briefly and send a few real requests through it? (uses a few hundred tokens)" Y; then
    SMOKE_PORT="$A2O_PORT"
    for _try in 1 2 3 4 5 6 7 8 9 10; do
        port_busy 127.0.0.1 "$SMOKE_PORT" || break
        SMOKE_PORT=$(( SMOKE_PORT + 1 ))
    done
    if [[ "$SMOKE_PORT" != "$A2O_PORT" ]]; then
        warn "Port $A2O_PORT is busy; testing on port $SMOKE_PORT instead."
    fi

    cat > "$TMP/smoke_lib.py" <<'SMOKEPY'
"""Live smoke-test helper.  usage: smoke_lib.py body KIND | check KIND FILE
check exit codes: 0 ok, 1 warning (works, but not what we hoped to see), 2 failure"""
import json
import sys

TOOL = {
    "name": "get_weather",
    "description": "Get the weather for a city",
    # the lookahead pattern is on purpose: it proves the schema sanitiser works upstream
    "input_schema": {"type": "object", "required": ["city"],
                     "properties": {"city": {"type": "string", "pattern": "^(?!-)[A-Za-z ]+$"}}},
}


def body(kind):
    b = {"model": "claude-sonnet-4-5", "max_tokens": 300}
    if kind == "basic":
        b.update(system="You are terse.",
                 messages=[{"role": "user", "content": "Reply with exactly: proxy ok"}])
    elif kind == "think":
        b.update(max_tokens=2048, stream=True, thinking={"type": "enabled", "budget_tokens": 1024},
                 messages=[{"role": "user", "content": "What is 17*23? Answer with just the number."}])
    elif kind == "tool":
        b.update(tools=[TOOL],
                 messages=[{"role": "user", "content": "What is the weather in Lagos? Use the tool."}])
    elif kind == "history":
        b.update(messages=[
            {"role": "user", "content": "What is 17*23?"},
            {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "17*23 = 391", "signature": "sig"},
                {"type": "text", "text": "391"}]},
            {"role": "user", "content": "Now double it. Answer with just the number."}])
    else:
        sys.exit("unknown kind " + kind)
    print(json.dumps(b))


def texts(content):
    return " ".join(x.get("text", "") for x in content if x.get("type") == "text").strip()


def check(kind, path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    if kind == "think":
        events = []
        for line in raw.splitlines():
            if line.startswith("data:"):
                try:
                    events.append(json.loads(line[5:].strip()))
                except ValueError:
                    pass
        if not events:
            print("no SSE events came back"); return 2
        starts = [e["content_block"]["type"] for e in events if e.get("type") == "content_block_start"]
        think = "".join(e["delta"].get("thinking", "") for e in events
                        if e.get("delta", {}).get("type") == "thinking_delta")
        text = "".join(e["delta"].get("text", "") for e in events
                       if e.get("delta", {}).get("type") == "text_delta")
        if "DSML" in text:
            print("DSML markup leaked into the text stream"); return 2
        if think.strip() and text.strip():
            print("streaming OK: thinking block (%d chars) then text %r" % (len(think), text.strip()[:40])); return 0
        print("streaming works but blocks were %s (thinking=%d chars, text=%d chars). "
              "The model may not reason, or this provider names the field something else."
              % (starts, len(think), len(text))); return 1
    data = json.loads(raw)
    if kind in ("basic", "history"):
        t = texts(data.get("content", []))
        if t:
            print("model said: " + t[:80]); return 0
        print("HTTP 200 but no text in the reply"); return 2
    if kind == "tool":
        uses = [b for b in data.get("content", []) if b.get("type") == "tool_use"]
        if uses and data.get("stop_reason") == "tool_use":
            print("tool_use %s %s" % (uses[0].get("name"), json.dumps(uses[0].get("input")))); return 0
        print("request accepted (so the schema patch works) but the model chose not to call the tool"); return 1
    return 2


if __name__ == "__main__":
    if sys.argv[1] == "body":
        body(sys.argv[2])
    else:
        sys.exit(check(sys.argv[2], sys.argv[3]))
SMOKEPY

    smoke_post() {   # smoke_post OUTFILE JSON_BODY -> prints the HTTP status
        printf 'header = "Authorization: Bearer %s"\n' "$TOKEN_VALUE" \
            | curl -sS -K - --max-time 180 -o "$1" -w '%{http_code}' \
                -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
                -d "$2" "http://127.0.0.1:$SMOKE_PORT/v1/messages" 2>/dev/null
    }

    smoke_case() {   # smoke_case KIND LABEL -> 0 ok/warn, 1 failed
        local kind="$1" label="$2" body code="" out="" rc=0
        body="$("$PYTHON" "$TMP/smoke_lib.py" body "$kind")"
        code="$(smoke_post "$TMP/smoke_$kind.out" "$body")" || code="000"
        if [[ "$code" != "200" ]]; then
            error "$label: HTTP $code $(head -c 300 "$TMP/smoke_$kind.out" 2>/dev/null)"
            return 1
        fi
        out="$("$PYTHON" "$TMP/smoke_lib.py" check "$kind" "$TMP/smoke_$kind.out" 2>&1)" || rc=$?
        case "$rc" in
            0) success "$label: $out" ;;
            1) warn "$label: $out" ;;
            *) error "$label: $out"; return 1 ;;
        esac
    }

    "$VENV_BIN/a2o$EXE" --host 127.0.0.1 --port "$SMOKE_PORT" --upstream "$BASE_URL" --model "$MODEL" \
        >"$LOG_FILE" 2>&1 &
    SMOKE_PID=$!
    READY=0
    for _ in $(seq 1 40); do
        if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SMOKE_PORT/health"; then READY=1; break; fi
        kill -0 "$SMOKE_PID" 2>/dev/null || break
        sleep 0.5
    done
    if [[ "$READY" -ne 1 ]]; then
        error "a2o did not start. Last log lines:"; tail -n 15 "$LOG_FILE" >&2
        warn "Smoke test skipped; offline tests already passed."
    else
        SMOKE_FAILED=0
        smoke_case basic   "1/4 plain request (system prompt + auth forwarded)" || SMOKE_FAILED=1
        smoke_case think   "2/4 streaming + thinking"                           || SMOKE_FAILED=1
        smoke_case tool    "3/4 tool call (schema has a lookahead pattern)"      || SMOKE_FAILED=1
        smoke_case history "4/4 follow-up turn carrying a thinking block"       || SMOKE_FAILED=1
        if [[ "$SMOKE_FAILED" -ne 0 ]]; then warn "Some smoke checks failed. Details: $LOG_FILE"; fi
    fi
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
else
    info "Skipped."
fi

# ---------- final output -----------------------------------------------------
section "SETUP COMPLETE"
if [[ "$THINKING" == "1" ]]; then
    THINK_NOTE="Thinking display: configured (MAX_THINKING_TOKENS=$THINKING_TOKENS in VS Code settings;
      alwaysThinkingEnabled + showThinkingSummaries in $CLAUDE_SETTINGS).
      Reload VS Code and start a NEW Claude Code session to see it."
else
    THINK_NOTE="Thinking display: not configured. Re-run this script and say yes to enable it."
fi
cat <<EOF

  Provider        $PROVIDER_NAME
  Upstream        $BASE_URL
  Model           $MODEL
  Local endpoint  http://$A2O_HOST:$A2O_PORT
  Config          $CONFIG_FILE (600)
  Launcher        $LAUNCHER
  VS Code         $VSCODE_SETTINGS

  Next steps
    1. Start the proxy and leave it running:   $LAUNCHER
    2. In VS Code run "Developer: Reload Window", then start a NEW Claude Code session.
    3. Ask it to read a file to confirm tool calls work end to end.

  Notes
    - Your key is in plain text in settings.json (ANTHROPIC_AUTH_TOKEN) because a2o forwards
      whatever Authorization header Claude Code sends.
    - a2o has no /v1/messages/count_tokens route; if Claude Code complains about it, tell me.
    - $THINK_NOTE
      Some providers silently serve a different model than the one you ask for; check the
      "model" field in a raw response if the behaviour looks off.
    - To change provider or model later, re-run this script and pick option 2 or 3.
    - Pristine copies of patched a2o files are kept next to them as *.orig.
    - Settings backups are kept as *.bak.<timestamp> (mode 600); only the newest $BACKUPS_KEEP per file.

EOF
