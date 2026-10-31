# FFXIV IDA Runner

Runs the usual post-patch IDA setup without babysitting every dialog.

## Requirements

This automates an existing setup; it does not install any of these for you.

- FFXIV, Git, and IDA 9 with working IDAPython (tested on 9.1 and 9.5).
- A local [FFXIVClientStructs](https://github.com/aers/FFXIVClientStructs) clone.
  Install `pyyaml` and `anytree` in the Python environment used by IDA; see its
  [IDA README](https://github.com/aers/FFXIVClientStructs/blob/main/ida/README.md) for details.
- New scripts also need [pythonnet](https://pythonnet.github.io/pythonnet/python.html#installation)
  (`python -m pip install pythonnet`, using IDA's Python) and the
  [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).
  MSVC headers must work with IDA's Clang version.
- The Hex-Rays decompiler if full C output is enabled.
- [ExtraPass](https://github.com/kweatherman/IDA_ExtraPass_PlugIn) if the chosen preset enables it.
- [FFXIVIDAComments](https://github.com/Haselnussbomber/FFXIVIDAComments) and
  its requirements, including the .NET SDK, if comments are enabled.

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

## Rough timings

These were clean runs from the executable on a Ryzen 7 7800X3D with IDA 9.1.
They include the whole runner, not just the time spent inside IDA.

| Preset | Time |
| --- | ---: |
| `favorite.json` | 1:03:18 |
| `no-comments.json` | 53:11 |
| `client-structs-only.json` | 11:38 |

The full C output is where most of the time goes. Treat these as rough numbers;
IDA version, game version, and hardware will all change them.

IDA 9.5+ reopens the database before ExtraPass to avoid slow FLIRT analysis.
The first log is `analysis.log`.

Each run's `pipeline-status.json` includes start, finish, and elapsed time for
every stage. `run.json` also records `post_pipeline_exit_seconds`, which covers
IDA cleanup after the pipeline says it is complete.

The presets are just starting points. The main switches are:

- `ida.visible` shows or hides IDA while it runs.
- `ida.user_directory` sets `IDAUSR` for this run, for separate plugin setups.
- `client_structs` selects `ffxiv_dx11.exe` or `__ImageBase`, SrcLang or legacy,
  full or array padding, and which function types are updated.
- `client_structs.generate_structs` runs CExporter for the new scripts (default: `true`).
- `client_structs.msvc_include_directory` can point to an older MSVC include folder.
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
