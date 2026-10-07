# Windows Codex provider setup

These two folders configure the OpenAI Codex CLI + VS Code extension directly.
No `ant2oai` adapter is used.

## Run from any of the three Windows shells

Each folder contains `setup.cmd`, which launches the PowerShell implementation.

- CMD: `setup.cmd`
- PowerShell: `.\setup.cmd`
- Git Bash: `./setup.cmd`

The script:

1. Prompts for the base URL and normalizes `/v1/chat/completions` to the `/v1` base.
2. Warns if the URL differs from the provider's expected URL.
3. Prompts for the API key and stores it persistently as a Windows **User** environment variable.
4. Fetches `/v1/models` and lets you select a model.
5. Checks for Codex CLI and offers installation if missing.
6. Checks for the official Codex VS Code extension (`openai.chatgpt`) and offers installation if missing.
7. Backs up an existing `%USERPROFILE%\.codex\config.toml` before changing it.
8. Configures a custom Codex provider using the OpenAI Responses API.
9. Optionally sends one live `/v1/responses` test request.

Missing npm / `code` or a failed install is a warning, not a fatal error: the config step still runs.
If `CODEX_HOME` is set, the config is written there instead of `%USERPROFILE%\.codex`.
Top-level `model` / `model_provider` are only edited above the first `[table]`, so same-named keys in
`[profiles.*]` are left alone. Direct keys of an existing `[model_providers.<id>]` block are replaced
(sub-tables such as `http_headers` are kept); the backup has the old file.

## Provider defaults

### Dahl
- Base: `https://inference.dahl.global/v1`
- Key: `DAHL_API_KEY`

### Gonka Router
- Base: `https://api.gonkarouter.io/v1`
- Key: `GONKA_API_KEY`

The base URL is intentionally editable because the script also supports another OpenAI-compatible endpoint if you confirm the warning.

## Important

The script does not print API keys after entry. The persistent variable is stored at Windows User scope rather than requiring Administrator rights.

Dahl documents `/v1/responses` specifically for Codex and recommends a custom provider rather than the built-in OpenAI provider.

## Notes

- After setup, open a new terminal and fully restart VS Code so they see the new User environment variable.
- Git Bash (mintty) can hide PowerShell prompts; if so, run `winpty ./setup.cmd` or use Windows Terminal.
