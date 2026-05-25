# upload-to-releases

A GitHub Action that uploads files to GitHub Releases using the GitHub REST API.

[English](README.md) | [简体中文](README.cn.md)

## Usage

Reference this Action in a `.github/workflows/*.yml` workflow file, for example [upload.yml](https://github.com/ophub/amlogic-s9xxx-armbian/blob/main/.github/workflows/build-armbian-arm64-server-image.yml):

```yaml
- name: Upload files to Release
  uses: ophub/upload-to-releases@main
  with:
    tag: "Set the tag name"
    artifacts: <path>/*.txt
    gh_token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `tag` | **Required** | — | Tag name of the release to create or update (e.g. `v1.0.0`). |
| `artifacts` | **Required** | — | File path(s) to upload. Supports glob patterns and comma-separated values (e.g. `dist/*.zip` or `dist/*.zip,out/*.tar.gz`). |
| `gh_token` | **Required** | — | The [GITHUB_TOKEN](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token) used for API authentication is a built-in token that GitHub automatically provides for each workflow run, so you don't need to create it manually. |
| `repo` | Optional | Current repository | Target repository in `<owner>/<repo>` format. Defaults to the repository running the workflow. |
| `allow_updates` | Optional | `true` | Update the release metadata (name, body, flags) if a release for the given tag already exists. Set to `false` to skip metadata updates on existing releases. |
| `remove_artifacts` | Optional | `false` | Remove **all** existing assets from the release before uploading new ones. Takes priority over `replaces_artifacts`. |
| `replaces_artifacts` | Optional | `true` | Replace an existing asset that has the same filename. When `false`, uploading a duplicate filename will be skipped. |
| `upload_timeout` | Optional | `5` | Per-file upload timeout in **minutes**. If a single file upload exceeds this limit, it is automatically retried up to 3 times total; if all attempts fail the file is skipped and the next file is attempted. Set to `0` to disable the per-file max-time limit. Note: even when `upload_timeout=0`, the stall guard remains active, uploads that transfer less than 1 KB/s for 60 consecutive seconds will still trigger the retry mechanism. |
| `make_latest` | Optional | `true` | Mark this release as the latest release. Options: `true` / `false` / `legacy` (determined by date and semantic version). |
| `prerelease` | Optional | `false` | Mark this release as a pre-release. |
| `draft` | Optional | `false` | Mark this release as a draft. |
| `name` | Optional | `""` | Display title name of the release. Falls back to the tag name when omitted. |
| `body` | Optional | `""` | Markdown body text of the release. Overridden by `body_file` when both are set. |
| `body_file` | Optional | `""` | Path to a Markdown file whose content is used as the release body. Takes precedence over `body`. |
| `out_log` | Optional | `false` | Output detailed JSON logs for each step. Useful for debugging. |

## Outputs(optional)

| Output | Description |
|--------|-------------|
| `release_id` | Numeric ID of the created or updated release. |
| `html_url` | HTML URL of the release page (e.g. `https://github.com/owner/repo/releases/tag/v1.0.0`). |
| `upload_url` | Asset upload URL for the release (useful for custom upload steps). |
| `assets` | JSON object mapping each uploaded filename to its download URL (e.g. `{"file.zip":"https://...","image.img.gz":"https://..."}`). |

## Notes

- ✅ To upload files to a Release, you need to go to your repository's `Settings` > `Actions` > `General` > `Workflow permissions`, select `Read and write permissions`, and click the `Save` button. Alternatively, you can add the permissions configuration to your workflow file (.yml); the required [permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions) for uploading Release assets is `contents: write`.
- ✳️ If the specified `tag` does not yet exist in the repository, GitHub will automatically create it pointing to the default branch at the time of the release creation.
- ⚠️ Setting `remove_artifacts: true` deletes **all** existing assets before uploading; use with care.
- ♻️ When `replaces_artifacts` is `true` and a file with the same name already exists, the remote SHA-256 is compared against the local file first. If they match, the upload is skipped (no re-upload needed). If they differ — or if the remote asset has no digest — the old asset is deleted and re-uploaded.
- After all uploads complete, the action automatically verifies each file using the API-provided hash (`digest: sha256:<hex>`).

## Upload progress and logging

This action prints detailed real-time progress for every file:

```text
[ STEPS ] Expanding artifact patterns...
[ INFO  ] Total files to upload: [ 5 ]
[ INFO  ] ────────────────────────────────────────────────────────────────────────
[ INFO  ]    1/5     1.23 GiB   firmware-arm64.img.gz
[ INFO  ]    2/5    45.67 MiB   firmware-x86.img.gz
[ INFO  ]    3/5     2.10 MiB   checksums.sha256
[ INFO  ]    4/5    12.34 KiB   release-notes.md
[ INFO  ]    5/5      890 B     version.txt
[ INFO  ] ────────────────────────────────────────────────────────────────────────
[ INFO  ] Total: [ 5 ] files,  1.28 GiB
[ INFO  ] ────────────────────────────────────────────────────────────────────────

[ STEPS ] Starting upload of [ 5 ] file(s) to release [ 123456 ]...
[ FILE ] ┌─ (1/5) Uploading: [ firmware-arm64.img.gz ]
[ SIZE ] │  (1/5) Size: 1.23 GiB  MIME: application/gzip  timeout=5min
[ DONE ] │  (1/5) Upload completed in 87s: [ firmware-arm64.img.gz ]
[ DONE ] └─ (1/5) Download URL: [ https://github.com/owner/repo/releases/download/v1.0.0/firmware-arm64.img.gz ]

...
[ SUCCESS ] Upload summary: [ 5 ] total, [ 5 ] succeeded, [ 0 ] failed, [ 0 ] skipped.

[ STEPS ] Verifying upload integrity (SHA-256)...
[ INFO  ] ────────────────────────────────────────────────────────────────────────
[ SUCCESS ] OK   1/5 [ firmware-arm64.img.gz ]  [ sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 ]
[ SUCCESS ] OK   2/5 [ firmware-x86.img.gz   ]  [ sha256:d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5 ]
[ SUCCESS ] OK   3/5 [ checksums.sha256      ]  [ sha256:f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1 ]
[ SUCCESS ] OK   4/5 [ release-notes.md      ]  [ sha256:b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3 ]
[ SUCCESS ] OK   5/5 [ version.txt           ]  [ sha256:c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4 ]
[ INFO  ] ────────────────────────────────────────────────────────────────────────
[ SUCCESS ] Integrity summary: [ 5 ] total, [ 5 ] passed, [ 0 ] failed, [ 0 ] skipped.
```

## Links

- [GitHub REST API – Releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub REST API – Release Assets](https://docs.github.com/en/rest/releases/assets)
- [delete-releases-workflows](https://github.com/ophub/delete-releases-workflows)
- [amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)
- [amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)
- [luci-app-amlogic](https://github.com/ophub/luci-app-amlogic)
- [fnnas](https://github.com/ophub/fnnas)
- [kernel](https://github.com/ophub/kernel)
- [u-boot](https://github.com/ophub/u-boot)
- [firmware](https://github.com/ophub/firmware)

## License

upload-to-releases © OPHUB is licensed under [GPL-2.0](https://github.com/ophub/upload-to-releases/blob/main/LICENSE).
