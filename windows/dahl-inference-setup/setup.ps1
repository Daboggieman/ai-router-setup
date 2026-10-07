param(
    [switch]$SkipLiveTest
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 may not enable TLS 1.2 by default.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$ProviderId = "dahl"
$ProviderName = "Dahl"
$ExpectedBase = "https://inference.dahl.global/v1"
$ApiEnvName = "DAHL_API_KEY"

function Write-Info($m) { Write-Host "[*] $m" }
function Write-Ok($m) { Write-Host "[+] $m" }
function Write-Warn($m) { Write-Host "[!] $m" }

function Get-ErrorDetail($ErrorRecord) {
    $msg = $ErrorRecord.Exception.Message
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } else {
        try {
            $resp = $ErrorRecord.Exception.Response
            if ($resp) {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
        } catch { }
    }
    if ($body) {
        if ($body.Length -gt 500) { $body = $body.Substring(0, 500) + "..." }
        return "$msg - $body"
    }
    return $msg
}

function Normalize-BaseUrl([string]$InputUrl) {
    $u = $InputUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($u)) { throw "Base URL cannot be empty." }
    $u = $u -replace '(?i)/(chat/completions|responses|models)/?$', ''
    $u = $u.TrimEnd('/')
    if ($u -notmatch '^(?i)https?://[^/\s]+') {
        throw "Base URL must start with http:// or https:// (got: $InputUrl)"
    }
    return $u
}

function Get-Json([string]$Uri, [string]$ApiKey) {
    $headers = @{}
    if ($ApiKey) { $headers["Authorization"] = "Bearer $ApiKey" }
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -TimeoutSec 30
    } catch {
        throw "GET $Uri failed: $(Get-ErrorDetail $_)"
    }
}

function Read-ApiKey([string]$EnvName) {
    $existing = [Environment]::GetEnvironmentVariable($EnvName, "User")
    if ($existing) {
        $answer = Read-Host "$EnvName already exists. Replace it? [y/N]"
        if ($answer -notmatch '^(?i)y(es)?$') { return $existing }
    }

    while ($true) {
        $secure = Read-Host "Enter $ProviderName API key" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
        if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
        Write-Warn "API key cannot be empty."
    }
}

function Set-PersistentEnv([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, "User")
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Ok "$Name saved as a persistent Windows user environment variable."
}

function Get-Model([string]$BaseUrl, [string]$ApiKey) {
    $modelsUri = "$BaseUrl/models"
    Write-Info "Fetching models from $modelsUri ..."
    try {
        $r = Get-Json $modelsUri $ApiKey
        $models = @($r.data | ForEach-Object { $_.id } | Where-Object { $_ })
    } catch {
        Write-Warn $_.Exception.Message
        $models = @()
    }

    if ($models.Count -gt 0) {
        Write-Host ""
        Write-Host "Available models:"
        for ($i = 0; $i -lt $models.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $models[$i])
        }
        while ($true) {
            $choice = Read-Host "Select model number, or enter a model ID manually"
            $n = 0
            if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $models.Count) {
                return $models[$n - 1]
            }
            if ($choice -and $choice -notmatch '^\d+$') { return $choice.Trim() }
            Write-Warn "Invalid selection."
        }
    }

    Write-Warn "The provider did not return a usable model list."
    while ($true) {
        $manual = Read-Host "Enter the model ID"
        if ($manual.Trim()) { return $manual.Trim() }
    }
}

function Backup-Config([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Info "No existing Codex config found; nothing to back up."
        return
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$ConfigPath.bak-$stamp"
    Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
    Write-Ok "Backed up existing config to $backup"
}

# ---- TOML helpers ----

function ConvertTo-TomlString([string]$Value) {
    $v = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $v + '"'
}

# Top-level keys must live before the first [table] header. Split the file there
# so scalar edits can never touch a same-named key inside a table.
function Split-TomlTopLevel([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^[ \t]*\[')
    if ($m.Success) {
        return [pscustomobject]@{ Head = $Text.Substring(0, $m.Index); Tail = $Text.Substring($m.Index) }
    }
    return [pscustomobject]@{ Head = $Text; Tail = "" }
}

function Set-TomlScalar([string]$Text, [string]$Key, [string]$Value) {
    $parts = Split-TomlTopLevel $Text
    $head = $parts.Head
    $line = "$Key = " + (ConvertTo-TomlString $Value)
    $rx = New-Object System.Text.RegularExpressions.Regex('(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[^\r\n]*')

    if ($rx.IsMatch($head)) {
        $head = $rx.Replace($head, $line.Replace('$', '$$'), 1)
    } else {
        if ($head.Length -gt 0 -and -not $head.EndsWith("`n")) { $head += "`r`n" }
        $head += "$line`r`n"
        if ($parts.Tail.Length -gt 0 -and $head -notmatch '(\r?\n){2}$') { $head += "`r`n" }
    }
    return $head + $parts.Tail
}

function Upsert-TomlSection([string]$Text, [string]$Section, [string]$Body) {
    $pattern = '(?ms)^[ \t]*\[' + [regex]::Escape($Section) + '\][ \t]*(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)'
    $bodyCrlf = $Body -replace "`r?`n", "`r`n"
    $replacement = "[$Section]`r`n$bodyCrlf`r`n`r`n"
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern)

    if ($rx.IsMatch($Text)) {
        return $rx.Replace($Text, $replacement.Replace('$', '$$'), 1)
    }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`r`n" }
    if ($Text.Length -gt 0) { $Text += "`r`n" }
    return $Text + $replacement
}

function Update-CodexConfig([string]$ConfigPath, [string]$BaseUrl, [string]$Model) {
    $dir = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $text = if (Test-Path -LiteralPath $ConfigPath) { [System.IO.File]::ReadAllText($ConfigPath, $utf8) } else { "" }

    Backup-Config $ConfigPath

    $text = Set-TomlScalar $text "model_provider" $ProviderId
    $text = Set-TomlScalar $text "model" $Model

    $body = @(
        "name = $(ConvertTo-TomlString $ProviderName)"
        "base_url = $(ConvertTo-TomlString $BaseUrl)"
        "env_key = $(ConvertTo-TomlString $ApiEnvName)"
        'wire_api = "responses"'
        'requires_openai_auth = false'
        'supports_websockets = false'
    ) -join "`r`n"
    $text = Upsert-TomlSection $text "model_providers.$ProviderId" $body

    [System.IO.File]::WriteAllText($ConfigPath, $text, $utf8)
    Write-Ok "Codex config updated: $ConfigPath"
}

function Test-Responses([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    Write-Info "Testing POST $BaseUrl/responses ..."
    $uri = "$BaseUrl/responses"
    $headers = @{ Authorization = "Bearer $ApiKey" }
    $payload = @{
        model = $Model
        input = "Reply with exactly: CODEX_SETUP_TEST"
        stream = $false
    } | ConvertTo-Json -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    try {
        $r = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 90
        $out = $r.output_text
        if (-not $out -and $r.output) {
            $out = (($r.output | ForEach-Object {
                $_.content | ForEach-Object { $_.text }
            }) -join "")
        }
        Write-Ok "Responses API test succeeded."
        if ($out) { Write-Host "    Response: $out" }
        return $true
    } catch {
        Write-Warn "Responses API test failed: $(Get-ErrorDetail $_)"
        return $false
    }
}

# ---- main ----
Write-Host ""
Write-Host "=== $ProviderName + Codex for Windows ==="
Write-Host ""

$inputBase = Read-Host "Enter the provider base URL [$ExpectedBase]"
if ([string]::IsNullOrWhiteSpace($inputBase)) { $inputBase = $ExpectedBase }
$baseUrl = Normalize-BaseUrl $inputBase
$expected = Normalize-BaseUrl $ExpectedBase

if ($baseUrl -ne $expected) {
    Write-Warn "The entered base URL is different from the expected $ProviderName URL."
    $confirm = Read-Host "Continue with $baseUrl? [y/N]"
    if ($confirm -notmatch '^(?i)y(es)?$') { throw "Setup cancelled." }
}
if ($baseUrl -match '^(?i)http://') {
    Write-Warn "This URL is not HTTPS: your API key would be sent unencrypted."
    $confirm = Read-Host "Continue anyway? [y/N]"
    if ($confirm -notmatch '^(?i)y(es)?$') { throw "Setup cancelled." }
}

$apiKey = Read-ApiKey $ApiEnvName
Set-PersistentEnv $ApiEnvName $apiKey

$model = Get-Model $baseUrl $apiKey
Write-Host ""
Write-Ok "Selected model: $model"

$codex = Get-Command codex -ErrorAction SilentlyContinue
$code = Get-Command code -ErrorAction SilentlyContinue

if (-not $codex) {
    Write-Warn "Codex CLI is not installed or not in PATH."
    $installCli = Read-Host "Install Codex CLI now? [Y/n]"
    if ($installCli -notmatch '^(?i)n(o)?$') {
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-Warn "npm was not found. Install Node.js (https://nodejs.org), then run: npm install -g @openai/codex"
        } else {
            & npm install -g @openai/codex
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "npm install failed (exit code $LASTEXITCODE). Continuing with the config step."
            } else {
                Write-Ok "Codex CLI installed."
                $codex = Get-Command codex -ErrorAction SilentlyContinue
                if (-not $codex) {
                    Write-Warn "This process may need a new terminal to see the codex command."
                }
            }
        }
    }
}

$extensionInstalled = $false
if ($code) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $extensions = @(& code --list-extensions 2>$null) } catch { $extensions = @() }
    $ErrorActionPreference = $prevEap
    $extensionInstalled = $extensions -contains "openai.chatgpt"
}
if (-not $extensionInstalled) {
    if (-not $code) {
        Write-Warn "VS Code's 'code' command is not in PATH, so the Codex extension (openai.chatgpt) was not checked."
        Write-Warn "If you use VS Code, install 'openai.chatgpt' from the Extensions view or add VS Code to PATH and rerun."
    } else {
        Write-Warn "Codex VS Code extension (openai.chatgpt) is not installed."
        $installExt = Read-Host "Install the Codex VS Code extension now? [Y/n]"
        if ($installExt -notmatch '^(?i)n(o)?$') {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & code --install-extension openai.chatgpt
            $rc = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            if ($rc -ne 0) {
                Write-Warn "Extension install failed (exit code $rc). Continuing with the config step."
            } else {
                Write-Ok "Codex VS Code extension installed."
            }
        }
    }
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$config = Join-Path $codexHome "config.toml"
Update-CodexConfig $config $baseUrl $model

if (-not $SkipLiveTest) {
    $test = Read-Host "Run a live Codex Responses API test now? This sends one test request. [Y/n]"
    if ($test -notmatch '^(?i)n(o)?$') {
        [void](Test-Responses $baseUrl $apiKey $model)
    }
}

Write-Host ""
Write-Ok "Setup complete."
Write-Host "Provider : $ProviderName"
Write-Host "Model    : $model"
Write-Host "Base URL : $baseUrl"
Write-Host "API key  : $ApiEnvName (Windows User environment)"
Write-Host "Config   : $config"
Write-Host ""
Write-Warn "Open a NEW terminal and fully restart VS Code (close all windows) so they pick up $ApiEnvName."
