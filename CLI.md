# Command line import

Unidot can import `.unitypackage` archives without opening the editor window.
This is useful for scripted or batch imports, CI, and on machines where the
editor GUI is unstable during large imports.

The command line mode runs the same import pipeline as
`Project -> Tools -> Import .unitypackage...`. It starts a headless Godot
editor, imports everything in the package, saves, and quits.

## Requirements

- The Unidot Importer plugin must be enabled in the project
  (`Project Settings -> Plugins`). The command line mode lives in the plugin.
- The project must have been opened in the editor at least once, so that
  `.godot/` exists.
- On Godot versions without built-in FBX support (before 4.3), FBX2glTF must be
  configured in Editor Settings, just like for the GUI import.

## Quick start

Use the wrapper script that ships with the addon:

```sh
addons/unidot_importer/unidot-import.sh ~/Downloads/RockFREE.unitypackage
```

When the script runs from `addons/unidot_importer/` inside a project, it uses
that project. Otherwise, pass `--project`:

```sh
unidot-import.sh --project ~/games/MyGame A.unitypackage B.unitypackage
```

If you give several packages, they are imported one after another as a batch,
in the order given.

### Wrapper options

| Option | Meaning |
| --- | --- |
| `-p, --project DIR` | Godot project directory. Default: the project the addon is installed in, else the current directory. |
| `-g, --godot BIN` | Godot executable. Default: `$GODOT`, else `godot`. |
| `-i, --include-type DESC` | Also import a type that is skipped by default, e.g. `".cs Script"`. Repeatable. |
| `-s, --skip-type DESC` | Do not import this type, e.g. `".scene Scene"`. Repeatable. |
| `-t, --timeout SECONDS` | Abort if the import takes longer than this. |
| `-l, --log FILE` | Write all import warnings and errors to `FILE`. |
| `--strict` | Exit with code 1 if any asset reported errors. |
| `--gui` | Show the editor window during the import. It still quits when done. |

## Calling Godot directly

The wrapper is a thin layer over plain Godot arguments. Everything after `--`
is read by Unidot:

```sh
godot --headless --editor --path /path/to/project -- \
    --unidot-import=/abs/path/A.unitypackage \
    --unidot-import=/abs/path/B.unitypackage \
    --unidot-skip-type=".scene Scene" \
    --unidot-log=/tmp/unidot.log --unidot-strict
```

| Argument | Meaning |
| --- | --- |
| `--unidot-import=PATH` | Package to import: a `.unitypackage`, an extracted Unity asset folder, or a `.meta` file. Repeatable. This argument turns command line mode on. |
| `--unidot-include-type=DESC` | Same as the wrapper's `--include-type`. |
| `--unidot-skip-type=DESC` | Same as the wrapper's `--skip-type`. |
| `--unidot-timeout=SECONDS` | Same as the wrapper's `--timeout`. |
| `--unidot-log=FILE` | Same as the wrapper's `--log`. |
| `--unidot-strict` | Same as the wrapper's `--strict`. |
| `--unidot-no-quit` | Keep the editor running after the import. Useful together with a visible editor. |

Godot changes its working directory to the project, so relative paths are
resolved against the project directory. The wrapper always passes absolute
paths.

`--editor` is required: without it Godot runs the game, and the editor plugin
never loads.

## Type names

Types use the same names as the "Select by Type" section of the import dialog:
the file extension, a space, and the Unity type. Each import prints the types
it found in the package. Examples:

```
[unidot-cli] Types in package: .anim AnimationClip (imported), .asset Avatar (imported),
  .controller AnimatorController (imported), .fbx Model (imported), .mat Material (imported),
  .png Texture2D (imported), .prefab Prefab (imported), .scene Scene (imported)
```

- Unity scenes are listed as `".scene Scene"`, not `.unity`.
- `".cs Script"`, `".shader Shader"` and `".asset LightingDataAsset"` are
  skipped by default, as in the dialog.

If you name a type that occurs in none of the packages, the import prints a
warning. The warning usually means a typo.

## Output and exit codes

Progress is printed to stdout with the prefix `[unidot-cli]`. When each package
is done, a summary line shows how many assets were imported and how many
reported errors, along with the types found in the package. Each asset with
errors is listed at the end.

| Exit code | Meaning |
| --- | --- |
| 0 | Import finished. Individual assets may still have errors; see the summary. |
| 1 | Import finished, but assets reported errors (only with `--strict`). |
| 2 | Bad arguments, or a package was not found. |
| 3 | Timeout. |
| other | Exit status from Godot itself. For example, 134 means Godot aborted or crashed. |

Godot's own `ERROR:` lines also appear in the output. Many of them are expected
during an import, such as textures that are not written yet while models are
being preprocessed. Use the summary and the `--log` file to judge the result.

## Notes

- The import modifies the project in place, exactly like the GUI import. Use
  version control or a backup.
- Do not run a command line import while the same project is open in another
  editor. Both editors would write to `.godot/` and `unidot_asset_database.res`.
- Headless mode skips editor rendering, such as resource thumbnails, so it
  usually needs less memory than an import in the GUI.
