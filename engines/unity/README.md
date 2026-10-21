# engines/unity — Unity games

Tools and notes for Switch games built with Unity (IL2CPP). The core host needs nothing Unity-specific; this directory is what makes a Unity port
quick. Found while porting manosaba (Unity 6000.0.72f1).

## Shader extraction

```sh
pip install --no-deps -r engines/unity/requirements.txt
python3 engines/unity/shader_extract.py <RomFS>/Data <ExeFS>/main $DM_ROOT/<workspace.shader_capture>
```

It reads every Switch shader from the game files without running the game and writes the capture format of the host's `DM_SHDUMP`
(`<key>.ctl` + `<key>.data`, plus `index.tsv` naming the shader, pass and keywords of each key). Sources: `Shader` objects (Addressables bundles,
`*.assets`, `Resources/unity*`; the Switch platform blob of every subprogram), `ComputeShader` kernels, and shaders embedded in `main`. On manosaba
it produced 2740 shaders, a superset of everything a run captured, byte-identical. Next steps: [PORTING.md](../../PORTING.md) (stage map,
`dmsh_build.py`, `c1_guard.py`).

Only vertex, fragment and compute shaders are kept; other stages are listed and skipped (the translator does not support them).

## Touch input

Unity compiles the Switch player settings into a row of constant functions at the start of `main` (`mov w0, #value; ret`). The Input System
backend creates its touchscreen device only when the "touchscreen" setting returns 1; a game built without touch support returns 0 and never
reads `nn::hid` touch states. One `CUTS` rule in `rules.py` flips that constant (see `games/manosaba/rules.py` for the instruction and how the
setting was located). After that, touches arrive in screen pixels; the host maps them through the window crop the game sets
(`nvnWindowSetCrop`).

## Console-only UI

A game built for Switch may hide controls that a mouse or touch player needs, because the console player has buttons for them. manosaba's
library asks `Platform.IsConsole` at run time (`Application.platform` → its own platform enum); the witch book hid its "present evidence" button
that way, and on a phone there was no way to present. Find such checks by their call sites (`IsConsole`, `CurrentPlatform`, …) and flip only
the UI ones with a cut: the same platform value often also selects asset catalog paths and the save configuration. The Input System action
asset (a JSON string in `global-metadata.dat`, from the generated `*Actions` class) shows which console button an action is bound to.

## Other notes

- **Graphics**: Unity binds vertex and fragment shaders as separate single-stage programs and copies NVN objects by value; the graphics layer
  handles both (see `gfx/nvn/nvn_obj.h` for the object sizes checked against Unity).
- **Video**: `VideoPlayer` uses the Nintendo movie library in `subsdk0`; the host implements it on AVFoundation (`host/hle_movie.c`).
- **IL2CPP**: code is in `main`, metadata in `Data/Managed/Metadata/global-metadata.dat`. For manosaba (metadata v31) Il2CppInspectorRedux
  produced a usable C# dump with method addresses (`main` offsets); Cpp2IL did not load this NSO.
- **RomFS check**: `tools/new_game.py` picks the standard Unity files (`globalgamemanagers`, `level0`, `resources.assets`,
  `global-metadata.dat`, Addressables catalog …) as key files and checks the whole `Data` tree.
