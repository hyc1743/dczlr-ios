# Public Repository Checklist

Before making the repository public:

- Keep `Data/`, original PE/DLL files, save data, generated IPA files and `.dczdata` parts outside Git history.
- Run `python tools/validate_release_contract.py .`.
- Run `python -m unittest discover -s tests -v`.
- Generate the three parts locally with `tools/pack_resources.py` and verify them against the embedded manifest.
- Upload each `.dczdata` file as a separately named GitHub Release asset; do not rename or recompress it.
- Push a `v*` tag to trigger `.github/workflows/release-ios.yml`.
- Download the unsigned IPA from the Release and sign it with your own Apple identity.
- Copy all resource parts into the installed app's Documents root or `ResourcePacks/` directory.
- Export `log.txt` after import if a part is missing or hash validation fails.

The current Windows workspace cannot prove macOS Xcode compilation, IPA installation, or actual game playability. Those claims require the GitHub macOS runner and a physical device.
