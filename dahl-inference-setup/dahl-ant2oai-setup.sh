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
#   3. Applies four small compatibility patches to a2o (each one checked first):
#        - parser.py   accept role="system" entries inside messages[]
#        - request.py  fold the system prompt into the first user message
#                      (for endpoints that reject role="system")
#        - response.py DeepSeek DSML tool calls -> Anthropic tool_use
#        - streaming.py same, for streamed responses
#   4. Runs offline tests, then (optionally) a live smoke test
#   5. Writes config.env (600), a launcher, and your VS Code settings
#
# Safe to re-run. No sudo needed.
# =============================================================================

# shellcheck disable=SC1090
set -Eeuo pipefail

# ---------- configuration ----------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-$HOME/ant2oia}"
VENV_DIR="$INSTALL_DIR/.venv"
CONFIG_FILE="$INSTALL_DIR/config.env"
LAUNCHER="$INSTALL_DIR/start-dahl-claude.sh"
PATCH_HELPER="$INSTALL_DIR/a2o_patch.py"
LOG_FILE="$INSTALL_DIR/a2o.log"

# The patches were written and verified against this exact version.
A2O_VERSION="${A2O_VERSION:-0.1.6}"

A2O_HOST_DEFAULT="127.0.0.1"
A2O_PORT_DEFAULT="3578"
DEFAULT_BASE_URL="https://inference.dahl.global/v1/chat/completions"
DEFAULT_MODEL="deepseek-ai/DeepSeek-V4-Flash-0731"
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

command -v python3 >/dev/null 2>&1 || die "python3 is not installed."
command -v curl >/dev/null 2>&1 || die "curl is not installed."
PYTHON="$(command -v python3)"
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
if [[ -f "$CONFIG_FILE" ]]; then
    # Read saved values in a subshell so they cannot clobber script variables.
    SAVED_UPSTREAM="$( . "$CONFIG_FILE"; printf '%s' "${A2O_UPSTREAM:-}" )"
    SAVED_MODEL="$( . "$CONFIG_FILE"; printf '%s' "${A2O_MODEL:-}" )"
    SAVED_HOST="$( . "$CONFIG_FILE"; printf '%s' "${A2O_HOST:-}" )"
    SAVED_PORT="$( . "$CONFIG_FILE"; printf '%s' "${A2O_PORT:-}" )"
    SAVED_KEY="$( . "$CONFIG_FILE"; printf '%s' "${A2O_API_KEY:-}" )"
    SAVED_PROVIDER="$( . "$CONFIG_FILE"; printf '%s' "${A2O_PROVIDER_NAME:-}" )"
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
if [[ ! "$A2O_PORT" =~ ^[0-9]+$ ]] || (( A2O_PORT < 1 || A2O_PORT > 65535 )); then
    die "Invalid port: $A2O_PORT"
fi
A2O_DEBUG="0"
if confirm "Enable a2o --debug logging? (logs may contain your prompts)" N; then A2O_DEBUG="1"; fi

port_busy() { "$PYTHON" -c 'import socket,sys; s=socket.socket(); s.settimeout(1)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except OSError: sys.exit(1)' "$1" >/dev/null 2>&1; }

if port_busy "$A2O_PORT"; then
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
printf '%-20s %s\n' "a2o version:" "$A2O_VERSION (pinned)"
printf '%-20s %s\n' "Install directory:" "$INSTALL_DIR"
printf '%-20s %s\n' "VS Code settings:" "$VSCODE_SETTINGS"
printf '\n'
confirm "Continue with this configuration?" Y || { printf 'Setup cancelled.\n'; exit 0; }

# ---------- venv + install ---------------------------------------------------
section "Python environment"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    info "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
    success "Virtual environment created."
else
    success "Existing virtual environment found."
fi
# Use the venv's interpreter explicitly; no need to 'source activate'.
VENV_PYTHON="$VENV_DIR/bin/python"

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
Only 'pristine' files are modified, and a one-time pristine copy is kept as <file>.orig
"""
import importlib.util
import py_compile
import shutil
import sys
from pathlib import Path

MARK = "A2O-DSML-PATCH"


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

FILES = {
    "parser": ("converters/parser.py", PARSER),
    "request": ("converters/request.py", REQUEST),
    "response": ("converters/response.py", RESPONSE),
    "streaming": ("converters/streaming.py", STREAMING),
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


def parse_dsml_tool_calls(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Return (remaining_text, OpenAI-style tool_calls). Incomplete blocks are left as text."""
    if not text:
        return text, []
    start = find_dsml_start(text)
    if start < 0:
        return text, []
    end_m = _END_RE.search(text, start)
    if end_m is None:
        return text, []

    block = text[start:end_m.end()]
    remaining = (text[:start] + text[end_m.end():]).strip()
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
    if not calls:
        return text, []
    return remaining, calls
'''


def state(path, pairs):
    text = path.read_text(encoding="utf-8")
    if MARK in text:
        return "patched"
    if all(old in text for old, _ in pairs):
        return "pristine"
    return "unknown"


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    base = pkg_dir()
    states = {n: state(base / rel, pairs) for n, (rel, pairs) in FILES.items()}

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

    touched = []
    try:
        for n, (rel, pairs) in FILES.items():
            path = base / rel
            if states[n] != "pristine":
                print(f"{n}: already patched")
                continue
            orig = path.with_name(path.name + ".orig")
            if not orig.exists():
                shutil.copy2(path, orig)
            text = path.read_text(encoding="utf-8")
            for old, new in pairs:
                if text.count(old) != 1:
                    raise RuntimeError(f"{n}: expected block found {text.count(old)} times")
                text = text.replace(old, new, 1)
            path.write_text(text, encoding="utf-8")
            touched.append(path)
            print(f"{n}: patched")
        (base / "converters" / "dsml.py").write_text(DSML_SOURCE, encoding="utf-8")
        print("dsml: written")
        for n, (rel, _) in FILES.items():
            py_compile.compile(str(base / rel), doraise=True)
        py_compile.compile(str(base / "converters" / "dsml.py"), doraise=True)
    except Exception as exc:  # restore pristine files if anything failed
        for path in touched:
            orig = path.with_name(path.name + ".orig")
            if orig.exists():
                shutil.copy2(orig, path)
        print(f"FAILED: {exc} (pristine files restored)")
        return 4
    return 0


sys.exit(main())
PYEOF
chmod 600 "$PATCH_HELPER"

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
    *) die "Patching failed; pristine files were restored. See the message above." ;;
esac

# ---------- offline tests ----------------------------------------------------
section "Tests"

info "Test 1/5: system messages inside messages[] are extracted (all system shapes)"
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

info "Test 2/5: DSML parser"
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
assert partial_start_len("abc<" + P + "DS") == 4 and partial_start_len("abc") == 0
print("PASS")
PY

info "Test 3/5: non-streaming DSML -> Anthropic tool_use"
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

info "Test 4/5: request conversion never sends role=system upstream"
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

info "Test 5/5: streaming DSML -> tool_use (split across chunks)"
"$VENV_PYTHON" - <<'PY'
import json
from a2o.converters.streaming import convert_openai_stream_to_anthropic_sse
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
# plain streaming text must be unaffected
plain = [{"model": "m", "choices": [{"index": 0, "delta": {"content": c}, "finish_reason": None}]} for c in ["Hel", "lo <", "b>ok"]]
plain.append({"model": "m", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
d2 = [json.loads(e.split("data: ", 1)[1]) for e in convert_openai_stream_to_anthropic_sse(plain, "m")]
assert "".join(d["delta"]["text"] for d in d2 if d.get("delta", {}).get("type") == "text_delta") == "Hello <b>ok"
assert [d for d in d2 if d["type"] == "message_delta"][0]["delta"]["stop_reason"] == "end_turn"
print("PASS")
PY
success "All 5 offline tests passed."

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
EOF
)
chmod 600 "$CONFIG_FILE"
success "Saved $CONFIG_FILE (permissions 600)"

# ---------- launcher ---------------------------------------------------------
section "Creating launcher"

cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
# Starts the local a2o proxy using ~/ant2oia/config.env.   Usage: start-dahl-claude.sh
set -Eeuo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$INSTALL_DIR/config.env"
A2O_BIN="$INSTALL_DIR/.venv/bin/a2o"

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
mkdir -p "$(dirname "$VSCODE_SETTINGS")"

print_manual_snippet() {
    warn "Add this to your VS Code user settings.json by hand:"
    cat <<EOF

"claudeCode.environmentVariables": [
    { "name": "ANTHROPIC_BASE_URL", "value": "http://$A2O_HOST:$A2O_PORT" },
    { "name": "ANTHROPIC_AUTH_TOKEN", "value": "${API_KEY:+<your API key>}${API_KEY:-$PLACEHOLDER_TOKEN}" },
    { "name": "ANTHROPIC_MODEL", "value": "$MODEL" }
]

EOF
}

if [[ -f "$VSCODE_SETTINGS" ]]; then
    cp "$VSCODE_SETTINGS" "$VSCODE_SETTINGS.bak.$TIMESTAMP"
    success "Backed up existing settings.json -> settings.json.bak.$TIMESTAMP"
fi

SETTINGS_RC=0
SETTINGS_OUT="$("$VENV_PYTHON" - "$VSCODE_SETTINGS" "http://$A2O_HOST:$A2O_PORT" "$TOKEN_VALUE" "$MODEL" <<'PY' 2>&1
import json, os, sys, tempfile
from pathlib import Path

path = Path(sys.argv[1]); base_url, token, model = sys.argv[2:5]
try:
    text = path.read_text(encoding="utf-8-sig") if path.exists() else ""
    settings = json.loads(text) if text.strip() else {}
except json.JSONDecodeError as exc:
    print("settings.json is not strict JSON (comments or trailing commas?): %s" % exc)
    sys.exit(3)
if not isinstance(settings, dict):
    print("settings.json must contain a JSON object"); sys.exit(3)

key = "claudeCode.environmentVariables"
existing = settings.get(key, [])
if not isinstance(existing, list):
    print("%s exists but is not an array; refusing to overwrite it" % key); sys.exit(3)

managed = {"ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"}
removed = [e["name"] for e in existing if isinstance(e, dict) and e.get("name") in managed]
kept = [e for e in existing if not (isinstance(e, dict) and e.get("name") in managed)]
kept += [
    {"name": "ANTHROPIC_BASE_URL", "value": base_url},
    {"name": "ANTHROPIC_AUTH_TOKEN", "value": token},   # a2o forwards Authorization: Bearer <this>
    {"name": "ANTHROPIC_MODEL", "value": model},
]
settings[key] = kept
if "claudeCode.selectedModel" in settings:
    print("NOTE: claudeCode.selectedModel is set and may override ANTHROPIC_MODEL; consider removing it")

tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8")
json.dump(settings, tmp, indent=2, ensure_ascii=False); tmp.write("\n"); tmp.close()
os.replace(tmp.name, path)
if removed:
    print("Replaced existing entries: " + ", ".join(removed))
print("OK")
PY
)" || SETTINGS_RC=$?

if [[ "$SETTINGS_RC" -eq 0 ]]; then
    printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /'
    success "Claude Code environment variables configured."
else
    printf '%s\n' "$SETTINGS_OUT" | sed 's/^/  /' >&2
    warn "Could not edit settings.json automatically (it was not changed)."
    print_manual_snippet
fi

# ---------- optional live smoke test -----------------------------------------
section "Live smoke test (optional)"

if confirm "Start a2o briefly and send one real request through it? (uses a few tokens)" Y; then
    SMOKE_PORT="$A2O_PORT"
    if port_busy "$SMOKE_PORT"; then
        SMOKE_PORT="$(( A2O_PORT + 1 ))"
        warn "Port $A2O_PORT is busy; testing on port $SMOKE_PORT instead."
    fi
    "$VENV_DIR/bin/a2o" --host 127.0.0.1 --port "$SMOKE_PORT" --upstream "$BASE_URL" --model "$MODEL" \
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
        SM_BODY="$("$PYTHON" -c 'import json; print(json.dumps({"model": "claude-sonnet-4-5", "max_tokens": 200, "system": "You are terse.", "messages": [{"role": "user", "content": "Reply with exactly: proxy ok"}]}))')"
        SM_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN_VALUE" \
            | curl -sS -K - --max-time 120 -o "$TMP/smoke.json" -w '%{http_code}' \
                -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
                -d "$SM_BODY" "http://127.0.0.1:$SMOKE_PORT/v1/messages" 2>/dev/null)" || SM_CODE="000"
        if [[ "$SM_CODE" == "200" ]]; then
            SM_TEXT="$("$PYTHON" -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(" ".join(b.get("text","") for b in d.get("content", []) if b.get("type") == "text").strip()[:150])' "$TMP/smoke.json" 2>/dev/null || true)"
            success "End to end works (system prompt + auth forwarded). Model said: ${SM_TEXT:-<no text>}"
        else
            error "Smoke test failed (HTTP $SM_CODE): $(head -c 400 "$TMP/smoke.json" 2>/dev/null)"
            warn "Details: $LOG_FILE"
        fi
    fi
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
else
    info "Skipped."
fi

# ---------- final output -----------------------------------------------------
section "SETUP COMPLETE"
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
    - To change provider or model later, re-run this script and pick option 2 or 3.
    - Pristine copies of patched a2o files are kept next to them as *.orig.

EOF
