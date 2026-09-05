# Repository and complete submission archive

This repository was imported from `SepsisCare_Final_Submission_20260612.zip`.

The [submission release](https://github.com/ExusiaiHY/SepsisCare/releases/tag/submission-20260612) contains the original ZIP split into 23 parts, including every source file, document, installer, bundled runtime, and build artifact. Joining the parts restores the ZIP byte for byte.

## Files available in Git

348 original files (157,750,095 bytes before Git compression) are included for browsing. Their original relative paths and contents are preserved, except that `README.md` has an added notice explaining the release download. Both macOS source directories are preserved as supplied.

The following original files are available in the complete release ZIP:

| Category | Files | Uncompressed bytes |
| --- | ---: | ---: |
| `.build/` and `.swift_module_cache/` trees | 14,875 | 3,028,601,851 |
| `dist/` trees | 16 | 25,541,565 |
| `02_installers/` | 5 | 96,312,218 |

Download and extract the full ZIP before following installation instructions or checks that require the complete submission layout. The original package manifests and checksums describe that full layout.

The import adds `.gitignore`, `ARCHIVE_SHA256SUMS.txt`, `ARCHIVE_PARTS.json`, `restore_archive.py`, and this file. Original package scripts were not executed as part of the upload.

## Download and restore

Download all 23 numbered archive parts, `ARCHIVE_PARTS.json`, and `restore_archive.py` from the release into one folder. Run `python3 restore_archive.py` on macOS/Linux or `py restore_archive.py` on Windows. The script needs Python 3.8 or later, verifies each part, restores `SepsisCare_Final_Submission_20260612.zip`, and checks its SHA-256 against the original archive. Allow about 1.5 GB of additional disk space for the restored ZIP.

With an authenticated GitHub CLI, the complete download and restore commands are:

```sh
gh release download submission-20260612 --repo ExusiaiHY/SepsisCare --dir SepsisCare-submission
python3 SepsisCare-submission/restore_archive.py
```

The numbered parts are file fragments, so restore the full ZIP before opening it with an archive utility.

## Archive integrity

- Archive size: 1,492,554,011 bytes.
- Archive entries: 15,244 files and 4,872 directories.
- SHA-256: `94cb4aa37efa3c7e97fc742df2f80d1280260bd09c82fd0fa3bf66066825dd36`.

After restoring the ZIP, you can also verify it using the release checksum file:

```sh
shasum -a 256 -c ARCHIVE_SHA256SUMS.txt
```
