# FFXIV IDA Runner

Runs the usual post-patch IDA setup without babysitting every dialog.

This assumes IDA 9 is ready to go. The runner uses
[FFXIVClientStructs](https://github.com/aers/FFXIVClientStructs), with
[ExtraPass](https://github.com/kweatherman/IDA_ExtraPass_PlugIn) and
[FFXIVIDAComments](https://github.com/Haselnussbomber/FFXIVIDAComments) as
optional extras.

## Setup

1. Clone the repos for the parts you use.
2. Copy one of the files in `presets` to `config.json`.
3. Fill in the paths at the top of `config.json`.
4. Run `Run.cmd`.

`config.json` is ignored by Git. A different config can be selected with:

```text
Run.cmd -Config C:\path\to\another-config.json
```

Relative paths are resolved from the selected config file. You can also set
`FFXIV_IDA_RUNNER_CONFIG`, though most people can just use `config.json`.

## Presets

| Preset | What it runs |
| --- | --- |
| `favorite.json` | ExtraPass, FFXIVClientStructs, full C output, and comments |
| `no-comments.json` | ExtraPass and FFXIVClientStructs, including C output |
| `client-structs-only.json` | FFXIVClientStructs only, with no ExtraPass, comments, or C output |

The presets are just starting points. The main switches are:

- `ida.visible` shows or hides IDA while it runs.
- `client_structs` selects `ffxiv_dx11.exe` or `__ImageBase`, SrcLang or legacy,
  full or array padding, and which function types are updated.
- `extra_pass.mode` can be `configured` or `interactive`. Configured mode sets
  all six ExtraPass checkboxes, including its sound option. Interactive mode
  leaves the dialog open for you and requires visible IDA.
- `completion_sound` plays one Windows sound after the whole run. It is off by default.
- `backup` controls whether the previous database and C file are kept. Backups
  default to an `ida-history` folder beside the game executable and use the run date.
- `paths.sqpack_directory` can stay blank; it then uses `sqpack` beside the executable.
- `paths.database_output` and `paths.c_output` are separate. Leave either blank
  to put it beside the executable.

Use `Run.ps1 -PreflightOnly` to check a config without changing anything.
