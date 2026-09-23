---
kind: external_dependency
name: Next.js Landing 页面
slug: nextjs
category: external_dependency
category_hints:
    - framework_behavior
scope:
    - '**'
---

### Next.js 落地页
- **容器化**: 基于 node:22-alpine 的 Docker 镜像，支持 standalone 部署
- **环境变量**: NEXT_PUBLIC_SITE_URL 配置站点地址，默认 https://tomo.qiizo.cn
- **开发命令**: `pnpm dev` 启动开发服务器，`pnpm build` 构建生产版本