# upload-to-releases

使用 GitHub REST API 将文件上传到 GitHub Releases 的 Action。

[English](README.md) | [简体中文](README.cn.md)

## 使用说明

在 `.github/workflows/*.yml` 工作流脚本中引用此 Action 即可使用，例如 [upload.yml](https://github.com/ophub/amlogic-s9xxx-armbian/blob/main/.github/workflows/build-armbian-arm64-server-image.yml):

```yaml
- name: 上传文件到 Release
  uses: ophub/upload-to-releases@main
  with:
    tag: "设置 tags 名称"
    artifacts: <path>/*.txt
    gh_token: ${{ secrets.GITHUB_TOKEN }}
```

## 配置说明

可在工作流文件中配置以下选项：

| 选&nbsp;&nbsp;项 | 要&nbsp;&nbsp;求 | 默&nbsp;&nbsp;&nbsp;认&nbsp;&nbsp;&nbsp;值 | 说&nbsp;&nbsp;明 |
|-------|-------|-------|-------|
| `tag` | **必填** | — | 要创建或更新的 Release 标签名称（如 `v1.0.0`）。若指定的 `tag` 在仓库中尚不存在，将在创建 Release 时自动以默认分支的当前提交为基础创建该 Tag。 |
| `artifacts` | **必填** | — | 要上传的文件路径，支持 glob 通配符和逗号分隔的多路径（如 `dist/*.zip` 或 `dist/*.zip,out/*.tar.gz`）。 |
| `gh_token` | **必填** | — | 用于 API 认证的 [GITHUB_TOKEN](https://docs.github.com/zh/actions/tutorials/authenticate-with-github_token) 是 GitHub 自动为每个工作流运行提供的内置令牌，无需手动创建。 |
| `repo` | 可选 | 当前仓库 | 目标仓库，格式为 `<owner>/<repo>`，默认为运行工作流的仓库。 |
| `allow_updates` | 可选 | `true` | 当指定标签的 Release 已存在时，是否更新其元数据（名称、正文、标志位）。设为 `false` 则跳过已有 Release 的元数据更新。可选值：`true` / `false` |
| `remove_artifacts` | 可选 | `false` | 上传前是否删除 Release 中的**所有**现有资产文件。优先级高于 `replaces_artifacts`。请谨慎使用。可选值：`true` / `false` |
| `replaces_artifacts` | 可选 | `true` | 是否替换同名的已有资产文件。设为 `false` 时，上传同名文件时将会跳过，不进行替换。当为 `true` 且已存在同名文件时，系统会先通过 API 查询远端文件的 SHA-256 值，并与本地文件进行比对。若 SHA-256 相同，则跳过重新上传；若 SHA-256 不同或远端文件无 digest 信息，则删除旧资产并重新上传。可选值：`true` / `false` |
| `upload_timeout` | 可选 | `5` | 单个文件上传超时时间，单位为**分钟**。超时后自动重试，最多重试 3 次，全部失败后跳过当前文件并继续上传下一个。设为 `0` 表示禁用单文件最大时限。注意：即使设为 `0`，防卡死的速度守卫仍然有效，若上传速度连续 60 秒低于 1 KB/s，仍会触发重试机制。 |
| `make_latest` | 可选 | `true` | 是否将此 Release 标记为最新版本。可选值：`true` / `false` / `legacy`（由发布日期和语义化版本号决定）。 |
| `prerelease` | 可选 | `false` | 是否将此 Release 标记为预发布版本。可选值：`true` / `false` |
| `draft` | 可选 | `false` | 是否将此 Release 标记为草稿。可选值：`true` / `false` |
| `name` | 可选 | `""` | Release 的显示标题名称，留空时自动使用标签名。 |
| `body` | 可选 | `""` | Release 的 Markdown 正文内容。同时设置 `body_file` 时，此项被覆盖。 |
| `body_file` | 可选 | `""` | Release 正文内容的 Markdown 文件路径，优先级高于 `body`。 |
| `out_log` | 可选 | `false` | 是否输出每个步骤的详细 JSON 日志，便于调试。可选值：`true` / `false` |

## 输出参数(可选)

| 输出 | 说明 |
|------|------|
| `release_id` | 创建或更新的 Release 的数字 ID。 |
| `html_url` | Release 页面的 HTML 地址（如 `https://github.com/owner/repo/releases/tag/v1.0.0`）。 |
| `upload_url` | Release 资产上传 URL（可用于自定义上传步骤）。 |
| `assets` | JSON 对象，将每个已上传文件名映射到其下载地址（如 `{"file.zip":"https://...","image.img.gz":"https://..."}`）。 |

## 注意事项

- ✅ 上传文件到 Release 需要 `GITHUB_TOKEN` 具备仓库内容的写入权限，有以下两种授权方式：
  - **推荐 — 在工作流 job 中添加 [`permissions`](https://docs.github.com/zh/actions/reference/workflows-and-actions/workflow-syntax#permissions) 配置：**

    ```yaml
    jobs:
      build:
        permissions:
          contents: write
    ```

  - **或者** 进入仓库的 `Settings` > `Actions` > `General` > `Workflow permissions`，选择 `Read and write permissions`，然后点击 `Save` 保存。注意：YAML 配置方式优先级更高，且遵循最小权限原则，推荐优先使用。
- ♻️ 所有文件上传完成后，该 Action 会自动利用 API 提供的哈希值（`digest: sha256:<hex>`）对每个文件进行验证。

## 上传进度与日志

本 Action 会为每个文件实时打印详细进度，例如：

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

## 相关链接

- [GitHub REST API – Releases](https://docs.github.com/zh/rest/releases/releases)
- [GitHub REST API – Release Assets](https://docs.github.com/zh/rest/releases/assets)
- [delete-releases-workflows](https://github.com/ophub/delete-releases-workflows)
- [amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)
- [amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)
- [luci-app-amlogic](https://github.com/ophub/luci-app-amlogic)
- [fnnas](https://github.com/ophub/fnnas)
- [kernel](https://github.com/ophub/kernel)
- [u-boot](https://github.com/ophub/u-boot)
- [firmware](https://github.com/ophub/firmware)

## 许可协议

upload-to-releases © OPHUB is licensed under [GPL-2.0](https://github.com/ophub/upload-to-releases/blob/main/LICENSE).
