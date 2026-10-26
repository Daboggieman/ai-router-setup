#Requires -Version 5.1
<#
=============================================================================
 dahl-ant2oai-setup.ps1  (fixed edition, Windows / PowerShell port)

   Claude Code (VS Code)  --Anthropic /v1/messages-->  a2o @ 127.0.0.1:3578
        --OpenAI /v1/chat/completions-->  your provider (Dahl by default)

 What this script does (same as the bash version)
   1. Lets you pick Dahl or a custom OpenAI-compatible endpoint + model
   2. Installs a PINNED ant2oai (a2o) version into %USERPROFILE%\ant2oia\.venv
   3. Applies six small compatibility patches to a2o (each one checked first):
        - parser.py   accept role="system" entries inside messages[]
        - request.py  fold the system prompt into the first user message
                      (for endpoints that reject role="system")
        - response.py DeepSeek DSML tool calls -> Anthropic tool_use
        - streaming.py same, for streamed responses
        - request.py  strip regex lookahead/lookbehind "pattern" values from tool
                      JSON schemas (upstream rejects them as invalid regex)
        - streaming.py + response.py  read the model's reasoning from the
                      "reasoning" field too, so it reaches Claude Code as a
                      "thinking" block instead of being silently dropped
   4. Runs offline tests, then (optionally) a live smoke test
   5. Writes config.env (owner-only), a launcher, and your VS Code settings

 Safe to re-run. No admin rights needed.

 Run it:   right-click the .ps1 -> Run with PowerShell
           or double-click dahl-ant2oai-setup.bat (bypasses the execution policy)
           or in a terminal:  powershell -ExecutionPolicy Bypass -File .\dahl-ant2oai-setup.ps1
=============================================================================
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$IsWin = ($env:OS -eq 'Windows_NT')

# ---------- configuration ----------------------------------------------------
function Get-EnvOr([string]$Name, [string]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

$HomeDir = Get-EnvOr 'USERPROFILE' $HOME
$InstallDir = Get-EnvOr 'INSTALL_DIR' (Join-Path $HomeDir 'ant2oia')
$VenvDir = Join-Path $InstallDir '.venv'
$ConfigFile = Join-Path $InstallDir 'config.env'
$Launcher = Join-Path $InstallDir 'start-dahl-claude.ps1'
$LauncherCmd = Join-Path $InstallDir 'start-dahl-claude.cmd'
$PatchHelper = Join-Path $InstallDir 'a2o_patch.py'
$LogFile = Join-Path $InstallDir 'a2o.log'

if ($IsWin) { $VenvBinDir = Join-Path $VenvDir 'Scripts'; $ExeSuffix = '.exe' }
else        { $VenvBinDir = Join-Path $VenvDir 'bin';     $ExeSuffix = '' }
$VenvPython = Join-Path $VenvBinDir ('python' + $ExeSuffix)
$A2OBin = Join-Path $VenvBinDir ('a2o' + $ExeSuffix)

# The patches were written and verified against this exact version.
$A2OVersion = Get-EnvOr 'A2O_VERSION' '0.1.6'

$A2OHostDefault = '127.0.0.1'
$A2OPortDefault = '3578'
$DefaultBaseUrl = 'https://inference.dahl.global/v1/chat/completions'
$DefaultModel = 'deepseek-ai/DeepSeek-V4-Flash-0731'
$PlaceholderToken = 'a2o-local'   # used when the endpoint needs no key

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-DefaultVSCodeSettings {
    if ($IsWin) {
        $appData = Get-EnvOr 'APPDATA' (Join-Path $HomeDir 'AppData\Roaming')
        return (Join-Path $appData 'Code\User\settings.json')
    }
    if ($PSVersionTable.PSObject.Properties['OS'] -and "$($PSVersionTable.OS)" -match 'Darwin') {
        return (Join-Path $HomeDir 'Library/Application Support/Code/User/settings.json')
    }
    $xdg = Get-EnvOr 'XDG_CONFIG_HOME' (Join-Path $HomeDir '.config')
    return (Join-Path $xdg 'Code/User/settings.json')
}
$VSCodeSettings = Get-EnvOr 'VSCODE_SETTINGS' (Get-DefaultVSCodeSettings)

# ---------- output helpers ---------------------------------------------------
function Write-Info([string]$Message)    { Write-Host ''; Write-Host '[INFO] ' -ForegroundColor Cyan -NoNewline; Write-Host $Message }
function Write-Ok([string]$Message)      { Write-Host '[OK] ' -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn([string]$Message)    { Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Err([string]$Message)     { Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline; Write-Host $Message }
function Write-Section([string]$Title) {
    $bar = '=' * 60
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host (' ' + $Title) -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
}

# Die = fatal, error already explains why.  Stop-Setup = clean exit, user said no.
function Die([string]$Message) { throw (New-Object System.OperationCanceledException($Message)) }
function Stop-Setup { throw (New-Object System.OperationCanceledException('__CANCEL__')) }

# ---------- cleanup ----------------------------------------------------------
$script:WorkDir = $null
$script:SmokeProc = $null

function Stop-ProcessTree($Proc) {
    if ($null -eq $Proc) { return }
    try {
        if (-not $Proc.HasExited) {
            if ($IsWin) {
                # a2o.exe is a launcher shim that spawns python.exe; kill the whole tree.
                & taskkill.exe /PID $Proc.Id /T /F *> $null
            } else {
                Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
            }
            [void]$Proc.WaitForExit(3000)
        }
    } catch { }
}

function Invoke-Cleanup {
    Stop-ProcessTree $script:SmokeProc
    $script:SmokeProc = $null
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- native command + file helpers -------------------------------------
# Runs an external program without letting its stderr abort the script
# (Windows PowerShell 5.1 turns native stderr into terminating errors otherwise).
function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @(), [string]$StdIn = $null)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($null -ne $StdIn) { $raw = $StdIn | & $File @Arguments 2>&1 }
        else                  { $raw = & $File @Arguments 2>&1 }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($null -eq $code) { $code = 0 }
    $text = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ ExitCode = [int]$code; Output = $text }
}

# UTF-8 without BOM. LF line endings unless -CRLF.
function Write-TextFile([string]$Path, [string]$Text, [switch]$CRLF) {
    $Text = $Text -replace "`r`n", "`n"
    if ($CRLF) { $Text = $Text -replace "`n", "`r`n" }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Owner-only permissions (the equivalent of chmod 600).
function Set-PrivateFile([string]$Path) {
    try {
        if ($IsWin) {
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $r = Invoke-Native 'icacls.exe' @($Path, '/inheritance:r', '/grant:r', "${me}:(R,W)")
            if ($r.ExitCode -ne 0) { Write-Warn "Could not restrict permissions on $Path" }
        } else {
            [void](Invoke-Native 'chmod' @('600', $Path))
        }
    } catch {
        Write-Warn "Could not restrict permissions on ${Path}: $($_.Exception.Message)"
    }
}

function Get-Head([string]$Path, [int]$Count) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = [System.IO.File]::ReadAllText($Path)
    if ($t.Length -gt $Count) { return $t.Substring(0, $Count) }
    return $t
}

function Read-ConfigFile([string]$Path) {
    $h = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*#' -or $line.IndexOf('=') -lt 1) { continue }
        $i = $line.IndexOf('=')
        $h[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1)
    }
    return $h
}

function Test-PortBusy([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------- input helpers ----------------------------------------------------
function Read-Line([string]$Prompt) {
    $v = Read-Host -Prompt $Prompt
    if ($null -eq $v) { Die 'Input closed.' }
    return $v
}

function Read-Default([string]$Prompt, [string]$Default) {
    $v = Read-Line "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Read-Required([string]$Prompt) {
    while ($true) {
        $v = (Read-Line $Prompt).Trim()
        if ($v) { return $v }
        Write-Warn 'This value cannot be empty.'
    }
}

function Read-Secret([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    if ($null -eq $sec) { Die 'Input closed.' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $reply = Read-Line "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return ($reply.Trim() -match '^[Yy]')
}

# Accepts a base URL or a full chat-completions URL; returns the full URL (or $null).
function ConvertTo-UpstreamUrl([string]$Raw) {
    $u = $Raw.Trim()
    if ($u.EndsWith('/')) { $u = $u.Substring(0, $u.Length - 1) }
    if ($u -notmatch '^https?://') { return $null }
    if ($u -match '/chat/completions$') { return $u }
    $rest = $u.Substring($u.IndexOf('://') + 3)
    if ($rest.Contains('/')) { return "$u/chat/completions" }
    return "$u/v1/chat/completions"
}

function Find-Python {
    # Order matters: the "py" launcher first, then python, then python3.
    # The Microsoft Store "python.exe" stub exits non-zero, so it is skipped.
    $probe = 'import sys; print(sys.executable); sys.exit(0 if sys.version_info >= (3, 9) else 1)'
    $candidates = @(
        @{ Name = 'py';      Pre = @('-3') },
        @{ Name = 'python';  Pre = @() },
        @{ Name = 'python3'; Pre = @() }
    )
    foreach ($c in $candidates) {
        $cmd = Get-Command $c.Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        try {
            $r = Invoke-Native $cmd.Source (@($c.Pre) + @('-c', $probe))
        } catch { continue }
        if ($r.ExitCode -ne 0) { continue }
        $exe = ($r.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($exe -and (Test-Path -LiteralPath $exe.Trim())) { return $exe.Trim() }
    }
    return $null
}

# ---------- embedded Python helper (the a2o patcher) --------------------------
$PatchHelperSource = @'
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
SCHEMA_MARK = "A2O-SCHEMA-PATCH"


def write_lf(path, text):
    with open(str(path), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


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
    "streaming": ("converters/streaming.py", STREAMING, MARK),
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

    touched = []
    try:
        for n, (rel, pairs, _mark) in FILES.items():
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
            write_lf(path, text)
            touched.append(path)
            print(f"{n}: patched")
        write_lf(base / "converters" / "dsml.py", DSML_SOURCE)
        print("dsml: written")
        for n, (rel, _p, _m) in FILES.items():
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
'@

# ---------- embedded Python helper (VS Code settings.json editor) -------------
$SettingsEditSource = @'
import json, os, sys, tempfile
from pathlib import Path

path = Path(sys.argv[1]); base_url, model = sys.argv[2:4]; token = os.environ["A2O_TOKEN"]
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
'@

# ---------- embedded offline tests --------------------------------------------
$OfflineTests = @(
    @{ Title = 'system messages inside messages[] are extracted (all system shapes)'; Code = @'
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
'@ }
    @{ Title = 'DSML parser'; Code = @'
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
'@ }
    @{ Title = 'non-streaming DSML -> Anthropic tool_use'; Code = @'
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
'@ }
    @{ Title = 'request conversion never sends role=system upstream'; Code = @'
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
'@ }
    @{ Title = 'streaming DSML -> tool_use (split across chunks)'; Code = @'
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
'@ }
    @{ Title = 'tool schemas lose lookahead patterns but keep everything else'; Code = @'
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
'@ }
    @{ Title = 'streaming reasoning (field name ''reasoning'') -> thinking block, then text'; Code = @'
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
'@ }
    @{ Title = 'non-streaming reasoning (field name ''reasoning'') -> thinking block'; Code = @'
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
'@ }
)

# ---------- launcher templates --------------------------------------------------
$LauncherSource = @'
#Requires -Version 5.1
# Starts the local a2o proxy using config.env (same folder).
# Usage:  .\start-dahl-claude.ps1      (or double-click start-dahl-claude.cmd)
$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$InstallDir = $PSScriptRoot
$ConfigFile = Join-Path $InstallDir 'config.env'
$A2OBin = Join-Path $InstallDir '.venv\Scripts\a2o.exe'
if (-not (Test-Path -LiteralPath $A2OBin)) { $A2OBin = Join-Path $InstallDir '.venv/bin/a2o' }

if (-not (Test-Path -LiteralPath $ConfigFile)) { Write-Host "[ERROR] Missing $ConfigFile" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $A2OBin))     { Write-Host "[ERROR] a2o not found: $A2OBin" -ForegroundColor Red; exit 1 }

$cfg = @{}
foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
    if ($line -match '^\s*#' -or $line.IndexOf('=') -lt 1) { continue }
    $i = $line.IndexOf('=')
    $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1)
}

if (-not $cfg['A2O_UPSTREAM']) { Write-Host '[ERROR] A2O_UPSTREAM is not configured' -ForegroundColor Red; exit 1 }
if (-not $cfg['A2O_MODEL'])    { Write-Host '[ERROR] A2O_MODEL is not configured' -ForegroundColor Red; exit 1 }
$LocalHost = if ($cfg['A2O_HOST']) { $cfg['A2O_HOST'] } else { '127.0.0.1' }
$LocalPort = if ($cfg['A2O_PORT']) { $cfg['A2O_PORT'] } else { '3578' }
$Provider  = if ($cfg['A2O_PROVIDER_NAME']) { $cfg['A2O_PROVIDER_NAME'] } else { 'Custom' }

Write-Host ''
Write-Host "Provider : $Provider"
Write-Host "Upstream : $($cfg['A2O_UPSTREAM'])"
Write-Host "Model    : $($cfg['A2O_MODEL'])"
Write-Host "Local    : http://${LocalHost}:${LocalPort}"
Write-Host 'Stop with Ctrl+C.'
Write-Host ''

$a2oArgs = @('--host', $LocalHost, '--port', $LocalPort, '--upstream', $cfg['A2O_UPSTREAM'], '--model', $cfg['A2O_MODEL'])
if ($cfg['A2O_DEBUG'] -eq '1') { $a2oArgs += '--debug' }

# The API key is NOT given to a2o here: a2o forwards the Authorization header
# that Claude Code sends (ANTHROPIC_AUTH_TOKEN in VS Code settings).
& $A2OBin @a2oArgs
exit $LASTEXITCODE
'@

$LauncherCmdSource = @'
@echo off
rem Starts the local a2o proxy. Double-click me, or run from cmd / PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-dahl-claude.ps1" %*
if errorlevel 1 pause
'@

# =============================================================================
# main
# =============================================================================
function Invoke-Setup {
    if ([Console]::IsInputRedirected) { Die 'This script is interactive. Run it directly in a terminal.' }

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dahlsetup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    $Work = $script:WorkDir

    # ---------- banner ----------
    try { Clear-Host } catch { }
    Write-Host ''
    Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|     ant2oai / a2o + Claude Code setup (fixed edition)        |' -ForegroundColor Cyan
    Write-Host '|                  Windows / PowerShell port                   |' -ForegroundColor Cyan
    Write-Host '+--------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Claude Code -> a2o (local) -> OpenAI-compatible API -> model'
    Write-Host ''

    # ---------- requirements ----------
    Write-Section 'Checking requirements'

    $Python = Find-Python
    if (-not $Python) {
        Die ('Python 3.9 or newer was not found. Install it from https://www.python.org/downloads/ ' +
             '(tick "Add python.exe to PATH") or run: winget install Python.Python.3.12')
    }
    $r = Invoke-Native $Python @('-c', 'import venv, ensurepip')
    if ($r.ExitCode -ne 0) { Die 'Python venv/ensurepip is missing. Reinstall Python with the "pip" option enabled.' }
    $pyVer = (Invoke-Native $Python @('--version')).Output.Trim()
    Write-Ok "Python: $Python ($pyVer)"

    if (-not (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Die 'curl.exe was not found. It ships with Windows 10 (1803+) and Windows 11; install it or update Windows.'
    }
    $Curl = (Get-Command curl.exe -CommandType Application | Select-Object -First 1).Source

    if (Get-Command code -ErrorAction SilentlyContinue) { Write-Ok 'VS Code command detected.' }
    else { Write-Warn "'code' command not found; settings.json will still be edited directly." }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-Ok "Install directory: $InstallDir"

    # ---------- provider ----------
    Write-Section 'Choose your OpenAI-compatible backend'

    $saved = @{}
    if (Test-Path -LiteralPath $ConfigFile) { $saved = Read-ConfigFile $ConfigFile }
    $SavedUpstream = [string]$saved['A2O_UPSTREAM']
    $SavedModel    = [string]$saved['A2O_MODEL']
    $SavedHost     = [string]$saved['A2O_HOST']
    $SavedPort     = [string]$saved['A2O_PORT']
    $SavedKey      = [string]$saved['A2O_API_KEY']
    $SavedProvider = [string]$saved['A2O_PROVIDER_NAME']

    Write-Host ''
    Write-Host '  1) Dahl Inference'
    Write-Host "     $DefaultBaseUrl"
    Write-Host "     Default model: $DefaultModel"
    Write-Host ''
    Write-Host '  2) Custom OpenAI-compatible endpoint (you enter the URL and model)'
    if ($SavedUpstream) {
        Write-Host ''
        Write-Host '  3) Reuse saved configuration'
        Write-Host "     $SavedUpstream  ($SavedModel)"
    }
    Write-Host ''

    $BaseUrl = ''; $Model = ''; $ProviderName = ''
    while ($true) {
        $choice = (Read-Line 'Selection [1-3]').Trim()
        if ($choice -eq '1') {
            $BaseUrl = $DefaultBaseUrl; $Model = $DefaultModel
            $ProviderName = 'Dahl Inference'; break
        } elseif ($choice -eq '2') {
            while ($true) {
                $rawUrl = Read-Required 'Base URL or full chat-completions URL'
                $BaseUrl = ConvertTo-UpstreamUrl $rawUrl
                if ($BaseUrl) { break }
                Write-Warn 'The URL must start with http:// or https://'
            }
            Write-Info "Using upstream URL: $BaseUrl"
            $Model = Read-Required 'Model name (exactly as the provider lists it)'
            $ProviderName = 'Custom OpenAI-compatible provider'; break
        } elseif ($choice -eq '3') {
            if (-not $SavedUpstream) { Write-Warn 'No saved configuration exists.'; continue }
            $BaseUrl = $SavedUpstream; $Model = $SavedModel
            $ProviderName = if ($SavedProvider) { $SavedProvider } else { 'Saved configuration' }
            Write-Ok 'Saved configuration loaded.'; break
        } else {
            Write-Warn 'Please choose 1, 2, or 3.'
        }
    }

    if ($BaseUrl.StartsWith('https://inference.dahl.global/')) {
        Write-Info 'Tip: Dahl rotates model IDs. Check https://inference.dahl.global/v1/models if the model is rejected.'
    }

    # ---------- API key ----------
    Write-Section 'API key'

    $ApiKey = ''
    Write-Host 'a2o forwards the "Authorization: Bearer ..." header Claude Code sends, so the key'
    Write-Host 'must be sent as ANTHROPIC_AUTH_TOKEN. It is stored in config.env (owner-only) and in'
    Write-Host 'your VS Code user settings.json (plain text).'
    Write-Host ''
    Write-Host '  1) Enter an API key'
    Write-Host '  2) No key (keyless endpoint)'
    if ($SavedKey) { Write-Host '  3) Keep the saved API key' }
    Write-Host ''

    while ($true) {
        $choice = (Read-Line 'Selection [1-3]').Trim()
        if ($choice -eq '1') {
            $ApiKey = (Read-Secret 'Enter API key (input hidden)').Trim()
            if (-not $ApiKey) { Write-Warn 'Empty key.'; continue }
            if ($ApiKey -match '\s') { Write-Warn 'A key cannot contain spaces.'; continue }
            break
        } elseif ($choice -eq '2') {
            $ApiKey = ''; break
        } elseif ($choice -eq '3') {
            if (-not $SavedKey) { Write-Warn 'There is no saved key.'; continue }
            $ApiKey = $SavedKey; Write-Ok 'Using the saved key.'; break
        } else {
            Write-Warn 'Please choose 1, 2, or 3.'
        }
    }

    # ---------- local settings ----------
    Write-Section 'Local a2o settings'

    $LocalHost = Read-Default 'Local a2o host' $(if ($SavedHost) { $SavedHost } else { $A2OHostDefault })
    $LocalPort = Read-Default 'Local a2o port' $(if ($SavedPort) { $SavedPort } else { $A2OPortDefault })
    if ($LocalPort -notmatch '^\d+$' -or [int64]$LocalPort -lt 1 -or [int64]$LocalPort -gt 65535) {
        Die "Invalid port: $LocalPort"
    }
    $LocalPort = [string][int]$LocalPort
    $A2ODebug = '0'
    if (Read-YesNo 'Enable a2o --debug logging? (logs may contain your prompts)' $false) { $A2ODebug = '1' }

    if (Test-PortBusy ([int]$LocalPort)) {
        Write-Warn "Something is already listening on port $LocalPort (an older a2o launcher?)."
        Write-Warn 'Stop it before starting the new proxy. Setup can still continue.'
    }

    # ---------- upstream check ----------
    Write-Section 'Checking the upstream (a few tokens are used)'

    $upReq = Join-Path $Work 'up_req.json'
    $upOut = Join-Path $Work 'up.json'
    $upErr = Join-Path $Work 'up.err'
    $upBody = ConvertTo-Json -Compress -Depth 5 -InputObject @{
        model = $Model
        messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' })
        max_tokens = 16
    }
    Write-TextFile $upReq $upBody
    $curlArgs = @('-sS', '--max-time', '90', '--stderr', $upErr, '-o', $upOut, '-w', '%{http_code}',
                  '-H', 'Content-Type: application/json', '--data-binary', "@$upReq")
    $stdin = $null
    if ($ApiKey) {
        # The key goes in through stdin so it never shows up in the process list.
        $curlArgs = @('-K', '-') + $curlArgs
        $stdin = 'header = "Authorization: Bearer ' + $ApiKey + '"'
    }
    $curlArgs += $BaseUrl
    $res = Invoke-Native $Curl $curlArgs -StdIn $stdin
    $UpCode = if ($res.ExitCode -eq 0 -and $res.Output.Trim() -match '^\d{3}$') { $res.Output.Trim() } else { '000' }

    switch -Regex ($UpCode) {
        '^200$'            { Write-Ok 'Upstream answered: the URL, key and model work.' }
        '^(401|403)$'      { Write-Warn "Upstream rejected the key (HTTP $UpCode)." }
        '^402$'            { Write-Warn 'Key accepted but no balance/tokens allocated (HTTP 402).' }
        '^(400|404|422)$'  { Write-Warn "Upstream rejected the request (HTTP ${UpCode}): $(Get-Head $upOut 300)" }
        default            { Write-Warn "Could not verify the upstream (HTTP $UpCode) $(Get-Head $upErr 200)" }
    }
    if ($UpCode -ne '200') {
        if (-not (Read-YesNo 'Continue anyway?' $false)) { Stop-Setup }
    }

    # ---------- summary ----------
    Write-Section 'Configuration summary'
    $keyState = if ($ApiKey) { 'configured' } else { 'none' }
    Write-Host ('{0,-20} {1}' -f 'Provider:', $ProviderName)
    Write-Host ('{0,-20} {1}' -f 'Upstream URL:', $BaseUrl)
    Write-Host ('{0,-20} {1}' -f 'Model:', $Model)
    Write-Host ('{0,-20} {1}' -f 'Local endpoint:', "http://${LocalHost}:${LocalPort}")
    Write-Host ('{0,-20} {1}' -f 'API key:', $keyState)
    Write-Host ('{0,-20} {1}' -f 'a2o version:', "$A2OVersion (pinned)")
    Write-Host ('{0,-20} {1}' -f 'Install directory:', $InstallDir)
    Write-Host ('{0,-20} {1}' -f 'VS Code settings:', $VSCodeSettings)
    Write-Host ''
    if (-not (Read-YesNo 'Continue with this configuration?' $true)) { Stop-Setup }

    # ---------- venv + install ----------
    Write-Section 'Python environment'

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        Write-Info 'Creating virtual environment...'
        $r = Invoke-Native $Python @('-m', 'venv', $VenvDir)
        if ($r.ExitCode -ne 0) { Die "Could not create the virtual environment:`n$($r.Output)" }
        Write-Ok 'Virtual environment created.'
    } else {
        Write-Ok 'Existing virtual environment found.'
    }

    $curVer = ''
    $r = Invoke-Native $VenvPython @('-m', 'pip', 'show', 'ant2oai')
    if ($r.ExitCode -eq 0) {
        foreach ($l in ($r.Output -split "`n")) { if ($l -match '^Version:\s*(.+)$') { $curVer = $Matches[1].Trim() } }
    }
    if ($curVer -eq $A2OVersion) {
        Write-Ok "ant2oai $A2OVersion already installed."
    } else {
        $shown = if ($curVer) { $curVer } else { 'not installed' }
        Write-Info "Installing ant2oai==$A2OVersion (currently: $shown)..."
        $r = Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip')
        if ($r.ExitCode -ne 0) { Write-Warn "pip self-upgrade failed (continuing): $($r.Output)" }
        $r = Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', "ant2oai==$A2OVersion")
        if ($r.ExitCode -ne 0) { Die "pip could not install ant2oai==${A2OVersion}:`n$($r.Output)" }
        Write-Ok "ant2oai $A2OVersion installed."
    }

    # ---------- patches ----------
    Write-Section 'Compatibility patches'

    Write-TextFile $PatchHelper $PatchHelperSource
    Set-PrivateFile $PatchHelper

    Write-Info 'Checking which a2o files are already patched...'
    $r = Invoke-Native $VenvPython @($PatchHelper, 'status')
    if ($r.ExitCode -ne 0) { Die "Patch status check failed:`n$($r.Output)" }
    foreach ($l in ($r.Output -split "`n")) { if ($l.Trim()) { Write-Host "  $($l.Trim())" } }

    if ($r.Output -match '=unknown') {
        Write-Warn 'Some a2o files are neither pristine nor patched by this script'
        Write-Warn '(for example, edited by hand in an earlier attempt).'
        if (Read-YesNo "Reinstall a2o $A2OVersion cleanly so the patches can be applied?" $true) {
            $r2 = Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', '--force-reinstall', '--no-deps', "ant2oai==$A2OVersion")
            if ($r2.ExitCode -ne 0) { Die "Reinstall failed:`n$($r2.Output)" }
            Write-Ok 'ant2oai reinstalled.'
        } else {
            Die 'Cannot continue with unrecognized a2o files.'
        }
    }

    $r = Invoke-Native $VenvPython @($PatchHelper, 'apply')
    foreach ($l in ($r.Output -split "`n")) { if ($l.Trim()) { Write-Host "  $($l.Trim())" } }
    switch ($r.ExitCode) {
        0       { Write-Ok 'All patches are in place.' }
        3       { Die "a2o files still look different from version $A2OVersion. Try: `$env:A2O_VERSION='<other>' or reinstall." }
        default { Die 'Patching failed; pristine files were restored. See the message above.' }
    }

    # ---------- offline tests ----------
    Write-Section 'Tests'

    $total = $OfflineTests.Count
    $n = 0
    foreach ($t in $OfflineTests) {
        $n++
        Write-Info "Test $n/${total}: $($t.Title)"
        $tf = Join-Path $Work "test$n.py"
        Write-TextFile $tf $t.Code
        $r = Invoke-Native $VenvPython @($tf)
        if ($r.Output.Trim()) { Write-Host $r.Output.Trim() }
        if ($r.ExitCode -ne 0) { Die "Test $n/$total failed (exit code $($r.ExitCode)). Nothing after this point was run." }
    }
    Write-Ok "All $total offline tests passed."

    # ---------- save configuration ----------
    Write-Section 'Saving configuration'

    $cfgText = @(
        "# ant2oai / a2o configuration (generated $(Get-Date)). Keep this file private.",
        "A2O_PROVIDER_NAME=$ProviderName",
        "A2O_UPSTREAM=$BaseUrl",
        "A2O_MODEL=$Model",
        "A2O_HOST=$LocalHost",
        "A2O_PORT=$LocalPort",
        "A2O_API_KEY=$ApiKey",
        "A2O_DEBUG=$A2ODebug"
    ) -join "`n"
    Write-TextFile $ConfigFile ($cfgText + "`n")
    Set-PrivateFile $ConfigFile
    Write-Ok "Saved $ConfigFile (owner-only permissions)"

    # ---------- launcher ----------
    Write-Section 'Creating launcher'

    Write-TextFile $Launcher $LauncherSource -CRLF
    Write-TextFile $LauncherCmd $LauncherCmdSource -CRLF
    Write-Ok "Launcher: $Launcher"
    Write-Ok "Double-click version: $LauncherCmd"

    # ---------- VS Code settings ----------
    Write-Section 'Configuring VS Code Claude Code'

    $TokenValue = if ($ApiKey) { $ApiKey } else { $PlaceholderToken }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $VSCodeSettings) | Out-Null

    if (Test-Path -LiteralPath $VSCodeSettings) {
        Copy-Item -LiteralPath $VSCodeSettings -Destination "$VSCodeSettings.bak.$Timestamp"
        Write-Ok "Backed up existing settings.json -> settings.json.bak.$Timestamp"
    }

    $editPy = Join-Path $Work 'settings_edit.py'
    Write-TextFile $editPy $SettingsEditSource
    $env:A2O_TOKEN = $TokenValue
    try {
        $r = Invoke-Native $VenvPython @($editPy, $VSCodeSettings, "http://${LocalHost}:${LocalPort}", $Model)
    } finally {
        Remove-Item Env:\A2O_TOKEN -ErrorAction SilentlyContinue
    }

    if ($r.ExitCode -eq 0) {
        foreach ($l in ($r.Output -split "`n")) { if ($l.Trim()) { Write-Host "  $($l.Trim())" } }
        Write-Ok 'Claude Code environment variables configured.'
    } else {
        foreach ($l in ($r.Output -split "`n")) { if ($l.Trim()) { Write-Host "  $($l.Trim())" -ForegroundColor Red } }
        Write-Warn 'Could not edit settings.json automatically (it was not changed).'
        Write-Warn 'Add this to your VS Code user settings.json by hand:'
        $shownToken = if ($ApiKey) { '<your API key>' } else { $PlaceholderToken }
        Write-Host @"

"claudeCode.environmentVariables": [
    { "name": "ANTHROPIC_BASE_URL", "value": "http://${LocalHost}:${LocalPort}" },
    { "name": "ANTHROPIC_AUTH_TOKEN", "value": "$shownToken" },
    { "name": "ANTHROPIC_MODEL", "value": "$Model" }
]

"@
    }

    # ---------- optional live smoke test ----------
    Write-Section 'Live smoke test (optional)'

    if (Read-YesNo 'Start a2o briefly and send one real request through it? (uses a few tokens)' $true) {
        $smokePort = [int]$LocalPort
        if (Test-PortBusy $smokePort) {
            $smokePort = $smokePort + 1
            Write-Warn "Port $LocalPort is busy; testing on port $smokePort instead."
        }
        $errLog = "$LogFile.err"
        $startArgs = @('--host', '127.0.0.1', '--port', "$smokePort", '--upstream', $BaseUrl, '--model', $Model)
        $startArgs = $startArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $script:SmokeProc = Start-Process -FilePath $A2OBin -ArgumentList $startArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $LogFile -RedirectStandardError $errLog

        $ready = $false
        $healthOut = Join-Path $Work 'health.out'
        for ($i = 0; $i -lt 40; $i++) {
            $h = Invoke-Native $Curl @('-s', '-o', $healthOut, '--max-time', '2', "http://127.0.0.1:$smokePort/health")
            if ($h.ExitCode -eq 0) { $ready = $true; break }
            if ($script:SmokeProc.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }

        if (-not $ready) {
            Write-Err 'a2o did not start. Last log lines:'
            foreach ($f in @($LogFile, $errLog)) {
                if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 15 | ForEach-Object { Write-Host $_ } }
            }
            Write-Warn 'Smoke test skipped; offline tests already passed.'
        } else {
            $smReq = Join-Path $Work 'smoke_req.json'
            $smOut = Join-Path $Work 'smoke.json'
            $smBody = ConvertTo-Json -Compress -Depth 5 -InputObject @{
                model = 'claude-sonnet-4-5'
                max_tokens = 200
                system = 'You are terse.'
                messages = @(@{ role = 'user'; content = 'Reply with exactly: proxy ok' })
            }
            Write-TextFile $smReq $smBody
            $smArgs = @('-K', '-', '-sS', '--max-time', '120', '--stderr', (Join-Path $Work 'smoke.err'),
                        '-o', $smOut, '-w', '%{http_code}',
                        '-H', 'Content-Type: application/json', '-H', 'anthropic-version: 2023-06-01',
                        '--data-binary', "@$smReq", "http://127.0.0.1:$smokePort/v1/messages")
            $sm = Invoke-Native $Curl $smArgs -StdIn ('header = "Authorization: Bearer ' + $TokenValue + '"')
            $SmCode = if ($sm.ExitCode -eq 0 -and $sm.Output.Trim() -match '^\d{3}$') { $sm.Output.Trim() } else { '000' }
            if ($SmCode -eq '200') {
                $smText = ''
                try {
                    $d = [System.IO.File]::ReadAllText($smOut) | ConvertFrom-Json
                    $smText = (@($d.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ').Trim()
                    if ($smText.Length -gt 150) { $smText = $smText.Substring(0, 150) }
                } catch { }
                if (-not $smText) { $smText = '<no text>' }
                Write-Ok "End to end works (system prompt + auth forwarded). Model said: $smText"
            } else {
                Write-Err "Smoke test failed (HTTP $SmCode): $(Get-Head $smOut 400)"
                Write-Warn "Details: $LogFile"
            }
        }
        Stop-ProcessTree $script:SmokeProc
        $script:SmokeProc = $null
    } else {
        Write-Info 'Skipped.'
    }

    # ---------- final output ----------
    Write-Section 'SETUP COMPLETE'
    Write-Host @"

  Provider        $ProviderName
  Upstream        $BaseUrl
  Model           $Model
  Local endpoint  http://${LocalHost}:${LocalPort}
  Config          $ConfigFile (owner-only)
  Launcher        $Launcher
  VS Code         $VSCodeSettings

  Next steps
    1. Start the proxy and leave it running (double-click it, or run it in a terminal):
         $LauncherCmd
    2. In VS Code run "Developer: Reload Window", then start a NEW Claude Code session.
    3. Ask it to read a file to confirm tool calls work end to end.

  Notes
    - Your key is in plain text in settings.json (ANTHROPIC_AUTH_TOKEN) because a2o forwards
      whatever Authorization header Claude Code sends.
    - a2o has no /v1/messages/count_tokens route; if Claude Code complains about it, tell me.
    - Thinking display: a2o now passes the model's reasoning to Claude Code as "thinking"
      blocks. To see them, also add "alwaysThinkingEnabled": true and
      "showThinkingSummaries": true to %USERPROFILE%\.claude\settings.json, and a MAX_THINKING_TOKENS
      entry (e.g. 16000) to claudeCode.environmentVariables, then reload VS Code.
      Some providers silently serve a different model than the one you ask for; check the
      "model" field in a raw response if the behaviour looks off.
    - To change provider or model later, re-run this script and pick option 2 or 3.
    - Pristine copies of patched a2o files are kept next to them as *.orig.

"@
}

# ---------- entry point -------------------------------------------------------
$ExitCode = 0
try {
    Invoke-Setup
} catch [System.OperationCanceledException] {
    if ($_.Exception.Message -eq '__CANCEL__') {
        Write-Host 'Setup cancelled.'
    } else {
        Write-Err $_.Exception.Message
        $ExitCode = 1
    }
} catch {
    Write-Err ("Failed at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
    Write-Host 'Nothing after this point was run.' -ForegroundColor Red
    $ExitCode = 1
} finally {
    Invoke-Cleanup
}
exit $ExitCode
