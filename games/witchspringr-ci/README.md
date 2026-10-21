# witchspringr-ci — headless reproduction profile

Same module set / build ID as `../witchspringr`, but the RomFS check has no key files and no tree, so the macOS host
starts with an empty `DM_ROMFS` directory. Used by `.github/workflows/repro.yml` to reproduce the boot abort on a
cloud runner without the user's game data (the abort happens in `nninitStartup`, before the game touches the RomFS).
