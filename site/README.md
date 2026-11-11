# Fanyi 静态介绍页

无需构建，无外部依赖。资源均使用相对路径。

## 本地预览

直接打开 `site/index.html`，或在仓库根目录运行：

```sh
python3 -m http.server -d site
```

打开 `http://localhost:8000`。演示循环播放，可暂停；开启系统「减少动态效果」后显示静态最终状态。安装命令可复制；浏览器禁止自动复制时，会选中命令供手动复制。

## GitHub Pages

Settings → Pages → Deploy from branch → main 只支持根目录 `/` 或 `/docs`，不能直接选择 `/site`。

保留当前目录的简单方式：Settings → Pages → Source 选择 **GitHub Actions**，使用 GitHub 提供的 **Static HTML** Pages 模板，将上传 artifact 的 `path` 改为 `./site`。工作流需要 Pages 写入权限与 OIDC 权限，通过上传 Pages artifact、部署 Pages 两步发布；提交该工作流后即可部署。仓库暂未包含该 workflow 文件。

也可把页面及 assets 一起移到 `/docs`，再选择 Deploy from branch → main → `/docs`。

Open Graph 图片使用相对路径 `assets/icon-512.png`；部分社交平台只识别绝对地址，正式部署后可按实际站点地址调整该元数据。
