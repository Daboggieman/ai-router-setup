```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# GonkaRouter + Claude Code Interactive Setup
# ============================================================
#
# TWO SUPPORTED MODES
# -------------------
#
# MODE 1 — DIRECT ANTHROPIC
#
# Claude Code
#     ↓ Anthropic Messages API
# GonkaRouter
#     ↓
# Selected GonkaRouter model
#
#
# MODE 2 — THROUGH a2o
#
# Claude Code
#     ↓ Anthropic /v1/messages
# a2o @ 127.0.0.1:3578
#     ↓ OpenAI /v1/chat/completions
# GonkaRouter
#     ↓
# Selected GonkaRouter model
#
#
# GonkaRouter currently supports both Anthropic-compatible and
# OpenAI-compatible APIs.
#
# Official Anthropic-compatible base:
#
#     https://api.gonkarouter.io
#
# Official OpenAI-compatible base:
#
#     https://api.gonkarouter.io/v1
#
# OpenAI-compatible chat endpoint:
#
#     https://api.gonkarouter.io/v1/chat/completions
#
#
# THIS SCRIPT PROVIDES:
#
#   • Interactive connection mode
#   • Interactive base URL
#   • Interactive API key
#   • Interactive model
#   • Existing configuration reuse
#   • Secure API-key storage
#   • Configuration validation
#   • GonkaRouter connectivity test
#   • Claude Code VS Code settings configuration
#   • Optional a2o installation/configuration
#   • Local a2o launcher
#   • Model selection
#   • Optional prompt-caching disable
#   • Backups of VS Code settings
#   • No sudo/root required
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

INSTALL_DIR="$HOME/gonka-claude"

VENV_DIR="$INSTALL_DIR/.venv"

CONFIG_FILE="$INSTALL_DIR/config.env"

DIRECT_LAUNCHER="$INSTALL_DIR/start-gonka-claude.sh"

A2O_LAUNCHER="$INSTALL_DIR/start-gonka-a2o.sh"

TEST_SCRIPT="$INSTALL_DIR/test-gonka.sh"

A2O_HOST_DEFAULT="127.0.0.1"
A2O_PORT_DEFAULT="3578"

GONKA_BASE_DEFAULT="https://api.gonkarouter.io"

GONKA_OPENAI_DEFAULT="https://api.gonkarouter.io/v1"

GONKA_CHAT_DEFAULT="https://api.gonkarouter.io/v1/chat/completions"

GONKA_ANTHROPIC_DEFAULT="https://api.gonkarouter.io"

DEFAULT_MODEL="deepseek-ai/DeepSeek-V4-Flash-0731"

VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"


# ============================================================
# COLORS
# ============================================================

if [[ -t 1 ]]; then
    BLUE='\033[1;34m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    RED='\033[1;31m'
    CYAN='\033[1;36m'
    RESET='\033[0m'
else
    BLUE=''
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
    RESET=''
fi


# ============================================================
# OUTPUT HELPERS
# ============================================================

info() {
    printf '\n%b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"
}

success() {
    printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1"
}

error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2
}

die() {
    error "$1"
    exit 1
}

section() {
    printf '\n'
    printf '%b============================================================%b\n' "$CYAN" "$RESET"
    printf '%b %s%b\n' "$CYAN" "$1" "$RESET"
    printf '%b============================================================%b\n' "$CYAN" "$RESET"
}


# ============================================================
# INPUT HELPERS
# ============================================================

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value

    printf '%s [%s]: ' "$prompt" "$default"
    read -r value

    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}


prompt_required() {
    local prompt="$1"
    local value

    while true; do
        printf '%s: ' "$prompt"
        read -r value

        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return
        fi

        warn "This value cannot be empty."
    done
}


prompt_secret() {
    local prompt="$1"
    local value

    printf '%s: ' "$prompt"
    read -r -s value
    printf '\n'

    printf '%s' "$value"
}


# ============================================================
# BANNER
# ============================================================

clear 2>/dev/null || true

printf '%b\n' "$CYAN"

printf '%s\n' '╔══════════════════════════════════════════════════════════════╗'
printf '%s\n' '║              GonkaRouter + Claude Code                    ║'
printf '%s\n' '║              Interactive Setup                             ║'
printf '%s\n' '╚══════════════════════════════════════════════════════════════╝'

printf '%b\n' "$RESET"

printf '\n'

printf '%s\n' 'This installer supports two architectures:'
printf '\n'

printf '%s\n' '  1) DIRECT'
printf '%s\n' '     Claude Code → GonkaRouter → Model'
printf '\n'

printf '%s\n' '  2) A2O PROXY'
printf '%s\n' '     Claude Code → a2o → GonkaRouter → Model'
printf '\n'

printf '%s\n' 'GonkaRouter supports Anthropic-compatible Messages API'
printf '%s\n' 'and OpenAI-compatible Chat Completions API.'
printf '\n'


# ============================================================
# REQUIREMENTS
# ============================================================

section "Checking requirements"

command -v curl >/dev/null 2>&1 \
    || die "curl is not installed."

command -v python3 >/dev/null 2>&1 \
    || die "python3 is not installed."

PYTHON="$(command -v python3)"

info "Python:"
"$PYTHON" --version

if command -v code >/dev/null 2>&1; then
    success "VS Code command detected."
else
    warn "'code' command was not found."
    warn "VS Code settings can still be edited directly."
fi

if command -v claude >/dev/null 2>&1; then
    success "Claude Code CLI detected."
else
    warn "'claude' command was not found."
fi


# ============================================================
# CREATE INSTALL DIRECTORY
# ============================================================

section "Preparing installation directory"

mkdir -p "$INSTALL_DIR"

success "Installation directory:"
printf '  %s\n' "$INSTALL_DIR"


# ============================================================
# MODE SELECTION
# ============================================================

section "Choose connection mode"

printf '\n'

printf '%s\n' '  1) Direct GonkaRouter Anthropic API'
printf '%s\n' '     Claude Code talks directly to GonkaRouter.'
printf '%s\n' '     No a2o required.'
printf '\n'

printf '%s\n' '  2) GonkaRouter through a2o'
printf '%s\n' '     Claude Code → local a2o → GonkaRouter.'
printf '%s\n' '     Uses GonkaRouter OpenAI-compatible endpoint.'
printf '\n'

printf '%s\n' '  3) Reuse previous configuration'
printf '%s\n' '     Load the saved configuration if available.'
printf '\n'

while true; do
    printf 'Selection [1-3]: '
    read -r MODE_CHOICE

    case "$MODE_CHOICE" in

        1)
            CONNECTION_MODE="direct"
            PROVIDER_NAME="GonkaRouter"
            break
            ;;

        2)
            CONNECTION_MODE="a2o"
            PROVIDER_NAME="GonkaRouter via a2o"
            break
            ;;

        3)
            if [[ ! -f "$CONFIG_FILE" ]]; then
                warn "No previous configuration exists:"
                warn "  $CONFIG_FILE"
                continue
            fi

            # shellcheck disable=SC1090
            source "$CONFIG_FILE"

            CONNECTION_MODE="${CONNECTION_MODE:-direct}"
            PROVIDER_NAME="${PROVIDER_NAME:-GonkaRouter}"

            success "Previous configuration loaded."
            break
            ;;

        *)
            warn "Please choose 1, 2, or 3."
            ;;
    esac
done


# ============================================================
# BASE URL CONFIGURATION
# ============================================================

section "Configure GonkaRouter endpoint"

if [[ "$MODE_CHOICE" == "3" ]]; then

    if [[ "$CONNECTION_MODE" == "direct" ]]; then
        DEFAULT_SELECTED_URL="${GONKA_BASE_URL:-$GONKA_ANTHROPIC_DEFAULT}"
    else
        DEFAULT_SELECTED_URL="${GONKA_UPSTREAM:-$GONKA_CHAT_DEFAULT}"
    fi

    BASE_URL="$(prompt_default \
        'GonkaRouter base URL' \
        "$DEFAULT_SELECTED_URL")"

else

    if [[ "$CONNECTION_MODE" == "direct" ]]; then

        printf '\n'
        printf '%s\n' 'The official Anthropic-compatible base is:'
        printf '  %s\n' "$GONKA_ANTHROPIC_DEFAULT"
        printf '\n'

        printf 'Use the official GonkaRouter base? [Y/n]: '
        read -r USE_DEFAULT

        if [[ ! "$USE_DEFAULT" =~ ^[Nn]$ ]]; then
            BASE_URL="$GONKA_ANTHROPIC_DEFAULT"
        else
            BASE_URL="$(prompt_required \
                'Enter your Anthropic-compatible base URL')"
        fi

    else

        printf '\n'
        printf '%s\n' 'The official OpenAI-compatible base is:'
        printf '  %s\n' "$GONKA_OPENAI_DEFAULT"
        printf '\n'

        printf 'Use the official GonkaRouter OpenAI base? [Y/n]: '
        read -r USE_DEFAULT

        if [[ ! "$USE_DEFAULT" =~ ^[Nn]$ ]]; then
            BASE_URL="$GONKA_OPENAI_DEFAULT"
        else
            BASE_URL="$(prompt_required \
                'Enter your OpenAI-compatible base URL')"
        fi

    fi
fi


# ============================================================
# MODEL
# ============================================================

section "Configure model"

printf '\n'

printf '%s\n' 'Examples of GonkaRouter model IDs include:'
printf '%s\n' '  deepseek-ai/DeepSeek-V4-Flash-0731'
printf '%s\n' '  zai-org/GLM-5.3-Flash'
printf '%s\n' '  MiniMaxAI/MiniMax-M2.7'
printf '\n'

MODEL_DEFAULT="${GONKA_MODEL:-$DEFAULT_MODEL}"

MODEL="$(prompt_default \
    'Model ID' \
    "$MODEL_DEFAULT")"


# ============================================================
# API KEY
# ============================================================

section "Configure GonkaRouter API key"

printf '\n'

printf '%s\n' 'Enter your GonkaRouter API key.'
printf '%s\n' 'It will be stored locally with chmod 600.'
printf '\n'

printf '%s\n' 'Choose:'
printf '%s\n' '  1) Enter a new API key'
printf '%s\n' '  2) Reuse the saved API key'
printf '%s\n' '  3) Use no API key'
printf '\n'

while true; do

    printf 'Selection [1-3]: '
    read -r KEY_CHOICE

    case "$KEY_CHOICE" in

        1)
            API_KEY="$(prompt_secret 'GonkaRouter API key')"

            if [[ -z "$API_KEY" ]]; then
                warn "The API key is empty."
                printf 'Continue without a key? [y/N]: '
                read -r CONFIRM_EMPTY

                if [[ "$CONFIRM_EMPTY" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
            ;;

        2)
            if [[ -z "${GONKA_API_KEY:-}" ]]; then
                warn "No saved API key exists."
                continue
            fi

            API_KEY="$GONKA_API_KEY"
            success "Saved API key selected."
            break
            ;;

        3)
            API_KEY=""
            break
            ;;

        *)
            warn "Please choose 1, 2, or 3."
            ;;
    esac

done


# ============================================================
# DIRECT MODE SETTINGS
# ============================================================

if [[ "$CONNECTION_MODE" == "direct" ]]; then

    section "Direct Claude Code settings"

    printf '\n'

    printf '%s\n' 'GonkaRouter documents these Claude Code variables:'
    printf '%s\n' '  ANTHROPIC_BASE_URL'
    printf '%s\n' '  ANTHROPIC_AUTH_TOKEN'
    printf '%s\n' '  ANTHROPIC_MODEL'
    printf '%s\n' '  ANTHROPIC_SMALL_FAST_MODEL'
    printf '%s\n' '  DISABLE_PROMPT_CACHING'
    printf '\n'

    SMALL_MODEL_DEFAULT="${GONKA_SMALL_MODEL:-$MODEL}"

    SMALL_MODEL="$(prompt_default \
        'Small/fast model' \
        "$SMALL_MODEL_DEFAULT")"

    printf '\n'
    printf 'Disable prompt caching? [Y/n]: '
    read -r DISABLE_CACHE_CHOICE

    if [[ ! "$DISABLE_CACHE_CHOICE" =~ ^[Nn]$ ]]; then
        DISABLE_PROMPT_CACHING="1"
    else
        DISABLE_PROMPT_CACHING="0"
    fi

fi


# ============================================================
# A2O SETTINGS
# ============================================================

if [[ "$CONNECTION_MODE" == "a2o" ]]; then

    section "Local a2o settings"

    A2O_HOST="${A2O_HOST:-$A2O_HOST_DEFAULT}"
    A2O_PORT="${A2O_PORT:-$A2O_PORT_DEFAULT}"

    A2O_HOST="$(prompt_default \
        'Local a2o host' \
        "$A2O_HOST")"

    A2O_PORT="$(prompt_default \
        'Local a2o port' \
        "$A2O_PORT")"

    if [[ ! "$A2O_PORT" =~ ^[0-9]+$ ]] || \
       (( A2O_PORT < 1 || A2O_PORT > 65535 )); then
        die "Invalid a2o port: $A2O_PORT"
    fi

    DISABLE_PROMPT_CACHING="0"

fi


# ============================================================
# CONFIGURATION SUMMARY
# ============================================================

section "Configuration summary"

printf '%-24s %s\n' \
    "Mode:" \
    "$CONNECTION_MODE"

printf '%-24s %s\n' \
    "Provider:" \
    "$PROVIDER_NAME"

printf '%-24s %s\n' \
    "Endpoint:" \
    "$BASE_URL"

printf '%-24s %s\n' \
    "Model:" \
    "$MODEL"

printf '%-24s %s\n' \
    "API key:" \
    "$([[ -n "$API_KEY" ]] && printf 'configured' || printf 'none')"

if [[ "$CONNECTION_MODE" == "direct" ]]; then

    printf '%-24s %s\n' \
        "Small/fast model:" \
        "$SMALL_MODEL"

    printf '%-24s %s\n' \
        "Prompt caching:" \
        "$([[ "$DISABLE_PROMPT_CACHING" == "1" ]] && printf 'disabled' || printf 'enabled')"

else

    printf '%-24s %s\n' \
        "Local a2o:" \
        "http://${A2O_HOST}:${A2O_PORT}"

fi

printf '\n'

printf 'Continue? [Y/n]: '
read -r CONFIRM

if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    printf 'Setup cancelled.\n'
    exit 0
fi


# ============================================================
# SAVE CONFIGURATION
# ============================================================

section "Saving configuration"

mkdir -p "$INSTALL_DIR"

cat > "$CONFIG_FILE" <<EOF
# ============================================================
# GonkaRouter + Claude Code configuration
# ============================================================
#
# Generated:
#   $(date)
#
# Permissions:
#   600
#
# ============================================================

CONNECTION_MODE=$(printf '%q' "$CONNECTION_MODE")
PROVIDER_NAME=$(printf '%q' "$PROVIDER_NAME")

GONKA_BASE_URL=$(printf '%q' "$BASE_URL")
GONKA_UPSTREAM=$(printf '%q' "$BASE_URL")

GONKA_MODEL=$(printf '%q' "$MODEL")
GONKA_API_KEY=$(printf '%q' "$API_KEY")

A2O_HOST=$(printf '%q' "${A2O_HOST:-}")
A2O_PORT=$(printf '%q' "${A2O_PORT:-}")

GONKA_SMALL_MODEL=$(printf '%q' "${SMALL_MODEL:-$MODEL}")

DISABLE_PROMPT_CACHING=$(printf '%q' "${DISABLE_PROMPT_CACHING:-0}")
EOF

chmod 600 "$CONFIG_FILE"

success "Configuration saved:"
printf '  %s\n' "$CONFIG_FILE"

success "Configuration permissions: 600"


# ============================================================
# DIRECT MODE
# ============================================================

if [[ "$CONNECTION_MODE" == "direct" ]]; then

    section "Testing direct GonkaRouter connection"

    TEST_RESPONSE="$(
        curl -sS \
            --connect-timeout 15 \
            --max-time 60 \
            -X POST \
            "${BASE_URL%/}/v1/messages" \
            -H "x-api-key: $API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "$(cat <<JSON
{
  "model": "$MODEL",
  "max_tokens": 128,
  "messages": [
    {
      "role": "user",
      "content": "Reply with exactly: GONKA_OK"
    }
  ]
}
JSON
)"
    )" || {
        warn "The connectivity test failed."
        warn "This does not necessarily mean the configuration is wrong."
        warn "Check the endpoint, API key, model ID, and account balance."
        TEST_RESPONSE=""
    }

    if [[ -n "$TEST_RESPONSE" ]]; then
        if printf '%s' "$TEST_RESPONSE" | grep -q 'GONKA_OK'; then
            success "GonkaRouter returned the expected response."
        else
            warn "GonkaRouter responded, but the expected text was not found."
            printf '\nResponse:\n%s\n' "$TEST_RESPONSE"
        fi
    fi

fi


# ============================================================
# A2O MODE — CREATE VENV
# ============================================================

if [[ "$CONNECTION_MODE" == "a2o" ]]; then

    section "Preparing a2o environment"

    if [[ ! -d "$VENV_DIR" ]]; then
        info "Creating Python virtual environment..."

        "$PYTHON" -m venv "$VENV_DIR"

        success "Virtual environment created."
    else
        success "Existing virtual environment found."
    fi

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    VENV_PYTHON="$VENV_DIR/bin/python"

    info "Updating pip..."

    "$VENV_PYTHON" -m pip install --upgrade pip

    success "pip updated."

    info "Installing ant2oai..."

    "$VENV_PYTHON" -m pip install --upgrade ant2oai

    success "ant2oai installed."


    # ========================================================
    # LOCATE a2o
    # ========================================================

    A2O_PACKAGE="$(
        "$VENV_PYTHON" - <<'PY'
import a2o
from pathlib import Path

print(Path(a2o.__path__[0]))
PY
    )"

    [[ -d "$A2O_PACKAGE" ]] \
        || die "Could not locate installed a2o package."

    PARSER_FILE="$A2O_PACKAGE/converters/parser.py"
    REQUEST_FILE="$A2O_PACKAGE/converters/request.py"
    RESPONSE_FILE="$A2O_PACKAGE/converters/response.py"
    STREAMING_FILE="$A2O_PACKAGE/converters/streaming.py"
    DSML_FILE="$A2O_PACKAGE/converters/dsml.py"


    # ========================================================
    # BACKUPS
    # ========================================================

    section "Backing up a2o files"

    for file in \
        "$PARSER_FILE" \
        "$REQUEST_FILE" \
        "$RESPONSE_FILE" \
        "$STREAMING_FILE"
    do
        if [[ -f "$file" ]]; then
            cp "$file" "$file.bak.$TIMESTAMP"
            success "Backup: $file.bak.$TIMESTAMP"
        fi
    done


    # ========================================================
    # PATCH PARSER
    # ========================================================

    section "Applying Claude Code system-message compatibility"

    "$VENV_PYTHON" - "$PARSER_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "extracted_system: list[dict[str, Any]]" in text:
    print("parser.py already contains the compatibility patch.")
    raise SystemExit(0)

old = '''    messages_raw = data.get("messages")
    _validate(
        messages_raw is not None and isinstance(messages_raw, list) and len(messages_raw) > 0,
        "'messages' must contain at least one entry",
    )
    assert isinstance(messages_raw, list)  # guaranteed by validation
    messages = _parse_messages(messages_raw)

    system = _parse_system(data.get("system"))
'''

new = '''    messages_raw = data.get("messages")
    _validate(
        messages_raw is not None and isinstance(messages_raw, list) and len(messages_raw) > 0,
        "'messages' must contain at least one entry",
    )
    assert isinstance(messages_raw, list)  # guaranteed by validation

    # Some Claude Code requests may contain system messages inside
    # the messages array. Anthropic normally represents system
    # instructions as a top-level "system" field, so extract them
    # before parsing the remaining user/assistant messages.
    extracted_system: list[dict[str, Any]] = []
    filtered_messages: list[dict[str, Any]] = []

    for i, raw in enumerate(messages_raw):
        _validate(isinstance(raw, dict), f"messages[{i}] must be a JSON object")

        if raw.get("role") == "system":
            content = raw.get("content")

            if isinstance(content, str):
                extracted_system.append({
                    "type": "text",
                    "text": content,
                })

            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        extracted_system.append(block)

            continue

        filtered_messages.append(raw)

    messages = _parse_messages(filtered_messages)

    system = _parse_system(data.get("system"))

    if extracted_system:
        extracted = _parse_system(extracted_system)

        if system is None:
            system = extracted

        elif isinstance(system, str) and isinstance(extracted, str):
            system = system + "\\n\\n" + extracted

        elif isinstance(system, list) and isinstance(extracted, list):
            system = system + extracted
'''

if old not in text:
    raise SystemExit(
        "Expected parser.py block was not found."
    )

path.write_text(text.replace(old, new, 1))

print("parser.py patched.")
PY


    # ========================================================
    # PATCH REQUEST
    # ========================================================

    section "Applying role=system compatibility"

    "$VENV_PYTHON" - "$REQUEST_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "Dahl's OpenAI-compatible endpoint does not accept" in text:
    print("request.py already contains the system-role patch.")
    raise SystemExit(0)

old_insert = '''    if system_text:
        body["messages"].insert(0, {"role": "system", "content": system_text})
'''

new_insert = '''    # OpenAI-compatible backends may reject role="system".
    # Preserve the system prompt by prepending it to the
    # first user message.
    if system_text and openai_messages:
        for message in openai_messages:
            if message.get("role") == "user":
                content = message.get("content", "")

                message["content"] = (
                    system_text + "\\n\\n" + content
                    if content
                    else system_text
                )

                break
'''

if old_insert not in text:
    print("Original system insertion not found.")
    print("The installed a2o version may already use a different implementation.")
    raise SystemExit(0)

path.write_text(text.replace(old_insert, new_insert, 1))

print("request.py patched.")
PY


    # ========================================================
    # DSML PARSER
    # ========================================================

    section "Installing DeepSeek V4 DSML compatibility"

    cat > "$DSML_FILE" <<'PY'
"""Parse DeepSeek V4 DSML tool calls into OpenAI-compatible tool calls."""

from __future__ import annotations

import json
import re
import uuid
from typing import Any


DSML_START = "<｜DSML｜tool_calls>"
DSML_END = "</｜DSML｜tool_calls>"

_INVOKE_RE = re.compile(
    r'<｜DSML｜invoke\s+name="([^"]+)">(.*?)</｜DSML｜invoke>',
    re.DOTALL,
)

_PARAMETER_RE = re.compile(
    r'<｜DSML｜parameter\s+name="([^"]+)"(?:\s+string="(true|false)")?>(.*?)'
    r'</｜DSML｜parameter>',
    re.DOTALL,
)


def parse_dsml_tool_calls(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Extract DeepSeek DSML tool calls from text."""

    if not text or DSML_START not in text:
        return text, []

    start = text.find(DSML_START)
    end = text.find(DSML_END, start)

    if end == -1:
        return text, []

    end += len(DSML_END)

    prefix = text[:start]
    suffix = text[end:]

    remaining = (prefix + suffix).strip()

    block = text[start:end]

    calls: list[dict[str, Any]] = []

    for invoke_match in _INVOKE_RE.finditer(block):
        name = invoke_match.group(1)
        body = invoke_match.group(2)

        arguments: dict[str, Any] = {}

        for parameter_match in _PARAMETER_RE.finditer(body):
            param_name = parameter_match.group(1)
            string_flag = parameter_match.group(2)
            raw_value = parameter_match.group(3)

            if string_flag == "true":
                value: Any = raw_value
            else:
                try:
                    value = json.loads(raw_value)
                except json.JSONDecodeError:
                    value = raw_value

            arguments[param_name] = value

        calls.append(
            {
                "id": f"toolu_{uuid.uuid4().hex[:24]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(
                        arguments,
                        ensure_ascii=True,
                        separators=(",", ":"),
                    ),
                },
            }
        )

    return remaining, calls


def contains_dsml_tool_call(text: str) -> bool:
    return DSML_START in text


def has_complete_dsml_tool_call(text: str) -> bool:
    return DSML_START in text and DSML_END in text
PY


    # ========================================================
    # RESPONSE CONVERTER
    # ========================================================

    section "Installing DSML response conversion"

    "$VENV_PYTHON" - "$RESPONSE_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

import_line = "from a2o.converters.dsml import parse_dsml_tool_calls\n"

if import_line not in text:
    marker = "from a2o.models import AnthropicUsage\n"

    if marker in text:
        text = text.replace(
            marker,
            marker + import_line,
            1,
        )

start = text.find("def convert_openai_to_anthropic(")

if start == -1:
    raise SystemExit(
        "convert_openai_to_anthropic() not found."
    )

prefix = text[:start]

new_function = '''def convert_openai_to_anthropic(
    openai_resp: dict[str, Any], model: str | None = None
) -> dict[str, Any]:
    choices = openai_resp.get("choices") or []
    msg_id = openai_resp.get("id") or f"msg_{uuid.uuid4().hex[:24]}"

    content: list[dict[str, Any]] = []
    finish_reason: str | None = None
    used_model = model or openai_resp.get("model", "")

    if choices:
        first = choices[0]
        message = first.get("message", {})
        finish_reason = first.get("finish_reason")

        text = message.get("content")

        dsml_tool_calls = []

        if isinstance(text, str):
            text, dsml_tool_calls = parse_dsml_tool_calls(text)

        if dsml_tool_calls:
            finish_reason = "tool_calls"

        if text:
            content.append({
                "type": "text",
                "text": text,
            })

        additional = message.get("_additionalProperties") or {}

        reasoning = (
            additional.get("reasoning_content")
            or message.get("reasoning_content")
        )

        signature = (
            additional.get("thinking_signature")
            or message.get("_thinking_signature")
            or ""
        )

        if reasoning:
            if not text and reasoning.strip():
                content.append({
                    "type": "text",
                    "text": reasoning,
                })
            else:
                content.append({
                    "type": "thinking",
                    "thinking": reasoning,
                    "signature": signature,
                })

        redacted = (
            additional.get("redacted_thinking")
            or message.get("redacted_thinking")
        )

        if redacted:
            content.append(
                redacted
                if isinstance(redacted, dict)
                else {
                    "type": "redacted_thinking",
                    "data": redacted,
                }
            )

        tool_calls = list(
            message.get("tool_calls") or []
        )

        tool_calls.extend(dsml_tool_calls)

        for tc in tool_calls:
            func = tc.get("function", {})

            content.append({
                "type": "tool_use",
                "id": (
                    tc.get("id")
                    or f"toolu_{uuid.uuid4().hex[:24]}"
                ),
                "name": func.get("name", ""),
                "input": _parse_tool_arguments(
                    func.get("arguments")
                ),
            })

        if tool_calls:
            finish_reason = "tool_calls"

    return {
        "id": msg_id,
        "type": "message",
        "role": "assistant",
        "model": used_model,
        "stop_reason": _map_finish_reason(finish_reason),
        "stop_sequence": None,
        "content": content,
        "usage": _serialize_usage(
            _build_usage(openai_resp.get("usage"))
        ),
    }
'''

path.write_text(prefix + new_function)

print("response.py patched.")
PY


    # ========================================================
    # STREAMING
    # ========================================================

    section "Installing streaming DSML compatibility"

    "$VENV_PYTHON" - "$STREAMING_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

import_line = "from a2o.converters.dsml import parse_dsml_tool_calls\n"

if import_line not in text:
    lines = text.splitlines(keepends=True)

    insert_at = 0

    for i, line in enumerate(lines):
        if line.startswith("from ") or line.startswith("import "):
            insert_at = i + 1

    lines.insert(insert_at, import_line)

    text = "".join(lines)


if "_content_buffer: list[str]" not in text:

    marker = "        self._tool_calls: dict[int, dict[str, Any]] = {}\n"

    if marker in text:
        text = text.replace(
            marker,
            marker + "        self._content_buffer: list[str] = []\n",
            1,
        )


old_content = '''        if delta.get("content"):
            self._had_text = True
            idx = self._ensure_active_block(events, CONTENT_TEXT)
            events.append(
                _sse(
                    "content_block_delta",
                    {
                        "index": idx,
                        "delta": {
                            "type": "text_delta",
                            "text": delta["content"],
                        },
                    },
                )
            )
'''

new_content = '''        if delta.get("content"):
            self._had_text = True
            self._content_buffer.append(delta["content"])
'''

if old_content in text:
    text = text.replace(
        old_content,
        new_content,
        1,
    )


start = text.find("    def finalize(")

if start != -1:

    after = text.find("\n    def ", start + 5)

    if after == -1:
        after = len(text)

    new_finalize = '''    def finalize(self) -> list[str]:
        events: list[str] = []

        full_content = "".join(self._content_buffer)

        text_content, dsml_tool_calls = parse_dsml_tool_calls(
            full_content
        )

        if text_content:
            idx = self._ensure_active_block(
                events,
                CONTENT_TEXT,
            )

            events.append(
                _sse(
                    "content_block_delta",
                    {
                        "index": idx,
                        "delta": {
                            "type": "text_delta",
                            "text": text_content,
                        },
                    },
                )
            )

        for index, tool_call in enumerate(dsml_tool_calls):
            tool_call["index"] = index
            self._process_tool_call(
                events,
                tool_call,
            )

        if dsml_tool_calls:
            self.final_stop_reason = STOP_TOOL_USE

        self._close_active_block(events)

        self._flush_final_tool_calls(events)

        events.append(
            _sse(
                "message_delta",
                {
                    "delta": {
                        "stop_reason": self.final_stop_reason,
                        "stop_sequence": None,
                    },
                    "usage": self.usage,
                },
            )
        )

        events.append(
            _sse(
                "message_stop",
                {},
            )
        )

        return events
'''

    text = (
        text[:start]
        + new_finalize
        + text[after:]
    )

path.write_text(text)

print("streaming.py patched.")
PY


    # ========================================================
    # COMPILE
    # ========================================================

    section "Checking a2o Python syntax"

    "$VENV_PYTHON" -m py_compile \
        "$PARSER_FILE" \
        "$REQUEST_FILE" \
        "$RESPONSE_FILE" \
        "$STREAMING_FILE" \
        "$DSML_FILE"

    success "All a2o Python files compile successfully."


    # ========================================================
    # TEST SYSTEM EXTRACTION
    # ========================================================

    section "Testing system-message extraction"

    "$VENV_PYTHON" - <<'PY'
from a2o.converters.parser import parse_anthropic_request

data = {
    "model": "test",
    "max_tokens": 100,
    "messages": [
        {
            "role": "system",
            "content": "You are a coding assistant."
        },
        {
            "role": "user",
            "content": "Hello"
        }
    ]
}

req = parse_anthropic_request(data)

assert len(req.messages) == 1
assert req.messages[0].role == "user"
assert req.messages[0].content == "Hello"
assert req.system is not None

print("PASS: system-message extraction")
PY


    # ========================================================
    # TEST DSML
    # ========================================================

    section "Testing DeepSeek V4 DSML parser"

    "$VENV_PYTHON" - <<'PY'
import json

from a2o.converters.dsml import parse_dsml_tool_calls

sample = """<｜DSML｜tool_calls>
<｜DSML｜invoke name="read_file">
<｜DSML｜parameter name="file_path">/tmp/test.txt</｜DSML｜parameter>
<｜DSML｜parameter name="offset">3</｜DSML｜parameter>
<｜DSML｜parameter name="limit">400</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>"""

text, calls = parse_dsml_tool_calls(sample)

assert text == ""
assert len(calls) == 1

arguments = json.loads(
    calls[0]["function"]["arguments"]
)

assert arguments["file_path"] == "/tmp/test.txt"
assert arguments["offset"] == 3
assert arguments["limit"] == 400

print("PASS: DSML parser")
print("CALL:", calls)
PY


    # ========================================================
    # TEST RESPONSE
    # ========================================================

    section "Testing DSML → Anthropic tool_use"

    "$VENV_PYTHON" - <<'PY'
from a2o.converters.response import (
    convert_openai_to_anthropic,
)

data = {
    "id": "test-response",
    "model": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "choices": [
        {
            "index": 0,
            "finish_reason": "stop",
            "message": {
                "role": "assistant",
                "content": """<｜DSML｜tool_calls>
<｜DSML｜invoke name="read_file">
<｜DSML｜parameter name="file_path">/tmp/test.txt</｜DSML｜parameter>
<｜DSML｜parameter name="offset">3</｜DSML｜parameter>
<｜DSML｜parameter name="limit">400</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>""",
            },
        }
    ],
}

result = convert_openai_to_anthropic(data)

assert result["stop_reason"] == "tool_use"

tool = result["content"][0]

assert tool["type"] == "tool_use"
assert tool["name"] == "read_file"

assert tool["input"]["file_path"] == "/tmp/test.txt"
assert tool["input"]["offset"] == 3
assert tool["input"]["limit"] == 400

print("PASS: DSML → Anthropic tool_use")
print("STOP_REASON:", result["stop_reason"])
print("TOOL:", tool)
PY


    # ========================================================
    # CREATE A2O LAUNCHER
    # ========================================================

    section "Creating a2o launcher"

    cat > "$A2O_LAUNCHER" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="\$HOME/gonka-claude"
VENV_DIR="\$INSTALL_DIR/.venv"
CONFIG_FILE="\$INSTALL_DIR/config.env"

source "\$CONFIG_FILE"
source "\$VENV_DIR/bin/activate"

exec a2o \\
    --host "\$A2O_HOST" \\
    --port "\$A2O_PORT" \\
    --upstream "\$GONKA_UPSTREAM" \\
    --model "\$GONKA_MODEL" \\
    --debug
EOF

    chmod +x "$A2O_LAUNCHER"

    success "a2o launcher created:"
    printf '  %s\n' "$A2O_LAUNCHER"

fi


# ============================================================
# CREATE DIRECT LAUNCHER
# ============================================================

section "Creating Claude Code launcher"

cat > "$DIRECT_LAUNCHER" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="$HOME/gonka-claude"
CONFIG_FILE="$INSTALL_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found:"
    echo "        $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${GONKA_BASE_URL:-}" ]]; then
    echo "[ERROR] GONKA_BASE_URL is not configured."
    exit 1
fi

if [[ -z "${GONKA_MODEL:-}" ]]; then
    echo "[ERROR] GONKA_MODEL is not configured."
    exit 1
fi

export ANTHROPIC_BASE_URL="$GONKA_BASE_URL"

if [[ -n "${GONKA_API_KEY:-}" ]]; then
    export ANTHROPIC_AUTH_TOKEN="$GONKA_API_KEY"
fi

export ANTHROPIC_MODEL="$GONKA_MODEL"

if [[ -n "${GONKA_SMALL_MODEL:-}" ]]; then
    export ANTHROPIC_SMALL_FAST_MODEL="$GONKA_SMALL_MODEL"
fi

if [[ "${DISABLE_PROMPT_CACHING:-0}" == "1" ]]; then
    export DISABLE_PROMPT_CACHING=1
else
    unset DISABLE_PROMPT_CACHING || true
fi

echo
echo "============================================================"
echo " GonkaRouter + Claude Code"
echo "============================================================"
echo
echo "Endpoint : $ANTHROPIC_BASE_URL"
echo "Model    : $ANTHROPIC_MODEL"
echo
echo "Starting Claude Code..."
echo

exec claude "$@"
EOF

chmod +x "$DIRECT_LAUNCHER"

success "Direct Claude Code launcher created:"
printf '  %s\n' "$DIRECT_LAUNCHER"


# ============================================================
# CREATE TEST SCRIPT
# ============================================================

section "Creating GonkaRouter test script"

cat > "$TEST_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="$HOME/gonka-claude"
CONFIG_FILE="$INSTALL_DIR/config.env"

source "$CONFIG_FILE"

echo
echo "============================================================"
echo " GonkaRouter connectivity test"
echo "============================================================"
echo

echo "Model:"
echo "  $GONKA_MODEL"
echo

echo "Endpoint:"
echo "  $GONKA_BASE_URL"
echo

if [[ -z "${GONKA_API_KEY:-}" ]]; then
    echo "[ERROR] No API key configured."
    exit 1
fi

echo "Sending test request..."
echo

curl -sS \
    --connect-timeout 15 \
    --max-time 90 \
    -X POST \
    "${GONKA_BASE_URL%/}/v1/messages" \
    -H "x-api-key: $GONKA_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{
        \"model\": \"$GONKA_MODEL\",
        \"max_tokens\": 128,
        \"messages\": [
            {
                \"role\": \"user\",
                \"content\": \"Reply with exactly: GONKA_OK\"
            }
        ]
    }"

echo
echo
echo "============================================================"
echo " Test complete"
echo "============================================================"
EOF

chmod +x "$TEST_SCRIPT"

success "Test script created:"
printf '  %s\n' "$TEST_SCRIPT"


# ============================================================
# VS CODE SETTINGS
# ============================================================

section "Configuring VS Code"

mkdir -p "$(dirname "$VSCODE_SETTINGS")"

if [[ -f "$VSCODE_SETTINGS" ]]; then

    cp \
        "$VSCODE_SETTINGS" \
        "$VSCODE_SETTINGS.bak.$TIMESTAMP"

    success "VS Code settings backed up."

else

    printf '{}\n' > "$VSCODE_SETTINGS"

    success "VS Code settings created."

fi


"$PYTHON" \
    - "$VSCODE_SETTINGS" \
    "$CONNECTION_MODE" \
    "$BASE_URL" \
    "$MODEL" \
    "$API_KEY" \
    "${SMALL_MODEL:-$MODEL}" \
    "${DISABLE_PROMPT_CACHING:-0}" \
    "$A2O_HOST" \
    "$A2O_PORT" \
    <<'PY'

from pathlib import Path
import json
import sys

settings_path = Path(sys.argv[1])
mode = sys.argv[2]
base_url = sys.argv[3]
model = sys.argv[4]
api_key = sys.argv[5]
small_model = sys.argv[6]
disable_cache = sys.argv[7]
a2o_host = sys.argv[8]
a2o_port = sys.argv[9]

settings = json.loads(
    settings_path.read_text()
)

if not isinstance(settings, dict):
    raise SystemExit(
        "VS Code settings.json must contain a JSON object."
    )

key = "claudeCode.environmentVariables"

existing = settings.get(key, [])

if not isinstance(existing, list):
    raise SystemExit(
        f"{key} exists but is not an array."
    )

managed = {
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "DISABLE_PROMPT_CACHING",
}

filtered = [
    item
    for item in existing
    if not (
        isinstance(item, dict)
        and item.get("name") in managed
    )
]

if mode == "direct":

    filtered.append({
        "name": "ANTHROPIC_BASE_URL",
        "value": base_url,
    })

    if api_key:
        filtered.append({
            "name": "ANTHROPIC_AUTH_TOKEN",
            "value": api_key,
        })

    filtered.append({
        "name": "ANTHROPIC_MODEL",
        "value": model,
    })

    filtered.append({
        "name": "ANTHROPIC_SMALL_FAST_MODEL",
        "value": small_model,
    })

    if disable_cache == "1":
        filtered.append({
            "name": "DISABLE_PROMPT_CACHING",
            "value": "1",
        })

else:

    filtered.append({
        "name": "ANTHROPIC_BASE_URL",
        "value": f"http://{a2o_host}:{a2o_port}",
    })

    if api_key:
        filtered.append({
            "name": "ANTHROPIC_AUTH_TOKEN",
            "value": api_key,
        })

    filtered.append({
        "name": "ANTHROPIC_MODEL",
        "value": model,
    })

settings[key] = filtered

settings_path.write_text(
    json.dumps(
        settings,
        indent=2,
        ensure_ascii=False,
    ) + "\n"
)

PY

success "Claude Code VS Code environment configured."


# ============================================================
# FINAL VALIDATION
# ============================================================

section "Final validation"

if [[ "$CONNECTION_MODE" == "a2o" ]]; then

    "$VENV_DIR/bin/python" - <<'PY'
import a2o

from a2o.converters.dsml import (
    parse_dsml_tool_calls,
)

from a2o.converters.response import (
    convert_openai_to_anthropic,
)

print("a2o import:                  OK")
print("DSML parser import:          OK")
print("Response converter import:   OK")
PY

fi

success "Final validation complete."


# ============================================================
# FINAL SUMMARY
# ============================================================

section "SETUP COMPLETE"

printf '\n'

printf '%bConnection mode%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$CONNECTION_MODE"

printf '%bProvider%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$PROVIDER_NAME"

printf '%bEndpoint%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$BASE_URL"

printf '%bModel%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$MODEL"

printf '%bAPI key%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' \
    "$([[ -n "$API_KEY" ]] && printf 'configured' || printf 'none')"

printf '%bConfiguration%b\n' "$CYAN" "$RESET"
printf '  %s\n' "$CONFIG_FILE"
printf '  permissions: 600\n\n'

printf '%bVS Code settings%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$VSCODE_SETTINGS"


if [[ "$CONNECTION_MODE" == "direct" ]]; then

    printf '%bDIRECT MODE%b\n' "$CYAN" "$RESET"
    printf '\n'

    printf 'Start Claude Code with:\n'
    printf '  %s\n\n' "$DIRECT_LAUNCHER"

    printf 'Or run:\n'
    printf '  %s\n\n' "$TEST_SCRIPT"

    printf 'Claude Code will use:\n'
    printf '  %s\n' "$BASE_URL"
    printf '\n'

    printf 'No a2o proxy is required.\n\n'

else

    printf '%bA2O MODE%b\n' "$CYAN" "$RESET"
    printf '\n'

    printf 'Start a2o with:\n'
    printf '  %s\n\n' "$A2O_LAUNCHER"

    printf 'Then start a NEW Claude Code session.\n\n'

    printf 'Local endpoint:\n'
    printf '  http://%s:%s\n\n' "$A2O_HOST" "$A2O_PORT"

    printf 'Upstream:\n'
    printf '  %s\n\n' "$BASE_URL"

    printf 'The following compatibility fixes are installed:\n'
    printf '  ✓ system-message extraction\n'
    printf '  ✓ role=system compatibility\n'
    printf '  ✓ DeepSeek V4 DSML parser\n'
    printf '  ✓ DSML → OpenAI tool_call conversion\n'
    printf '  ✓ OpenAI tool_call → Anthropic tool_use\n'
    printf '  ✓ stop_reason=tool_use\n'
    printf '  ✓ streaming DSML handling\n\n'

fi


printf '%bRecommended real-agent test%b\n' "$CYAN" "$RESET"
printf '\n'

printf '%s\n' 'Ask Claude Code:'
printf '%s\n' '  Read /tmp/test.txt and tell me exactly what is inside it.'
printf '%s\n' '  Use the file-reading tool; do not ask me to paste it.'
printf '\n'


printf '%bConfiguration can be changed later%b\n' "$CYAN" "$RESET"
printf '\n'

printf 'Rerun this script and select:\n'
printf '  3) Reuse previous configuration\n'
printf '\n'

printf 'Then change the endpoint, model, API key, or connection mode.\n'
printf '\n'

printf '%s\n' '============================================================'
printf '%s\n' ' End of GonkaRouter setup'
printf '%s\n' '============================================================'
```
