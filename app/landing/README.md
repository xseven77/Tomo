# Tomo Landing

Next.js landing page for [Tomo](https://github.com/xseven77/Tomo).

## 开发

```bash
cd app/landing
pnpm install
pnpm dev
```

浏览器打开 [http://localhost:3000](http://localhost:3000)。

## 构建

```bash
pnpm build
pnpm start
```

## 说明

- 包管理使用 **pnpm**（见 `pnpm-lock.yaml`）
- 下载入口跳转到 GitHub Releases，不在本站托管安装包
- 生产域名：`https://codexling.qiizo.cn`
- 首页 App preview 中，菜单栏胶囊使用固定透明中性色，额度健康色只作用于文字；
  左侧圆灯独立表达任务状态。主窗口右上角额度胶囊继续使用自己的健康色表面。

## Docker

镜像位于仓库根目录 `docker/landing/Dockerfile`，通过 qiizo-docker-tools 构建与部署：

```bash
./bin/dk release codexling   # 在 qiizo-docker-tools 目录
qiizo-deploy codexling
```

## SEO

部署前复制 `.env.example` 为 `.env.local`（本地）或 `${QIIZO_DATA}/codexling/.env`（生产构建）：

```bash
NEXT_PUBLIC_SITE_URL=https://codexling.qiizo.cn
```
