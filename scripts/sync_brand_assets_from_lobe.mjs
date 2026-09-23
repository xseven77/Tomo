import { cp, mkdir, readFile, readdir, rm, writeFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDir, "..");
const catalogJsonPath = resolve(projectRoot, "assets/brands/catalog.json");
const catalogDir = resolve(projectRoot, "assets/brands/catalog");
const inventoryMdPath = resolve(projectRoot, "assets/brands/BRAND_INVENTORY.md");
const landingDest = resolve(projectRoot, "app/landing/public/brand-assets");
const appBundleDest = resolve(projectRoot, "app/Tomo/dist/Tomo.app/Contents/Resources/BrandAssets/catalog");

const lobePngDir = "/tmp/lobe_cache/static-png/dark";
const lobeSvgDir = "/tmp/lobe_cache/static-svg/icons";

const lobeAlias = {
  "google-gemini": "gemini",
  "gemini-cli": "gemini",
  "claude-code": "claude",
  "azure-ai": "azure",
  "aws-bedrock": "bedrock",
  "cloudflare-workers-ai": "cloudflare",
  "kimi-code": "kimi",
  "qwen-code": "qwen",
  "github-copilot": "copilot",
  "hugging-face": "huggingface",
  "siliconflow": "siliconcloud",
  "vertex-ai": "vertexai",
  "lm-studio": "lmstudio",
  "pi-agent": "pi",
  "hermes-agent": "hermesagent"
};

async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function main() {
  console.log("Reading catalog.json...");
  const catalog = JSON.parse(await readFile(catalogJsonPath, "utf8"));
  const allBrands = [
    ...catalog.agents.map(id => ({ id, type: "Agent" })),
    ...catalog.providers.map(id => ({ id, type: "Provider" }))
  ];

  let lobePngFiles = [];
  let lobeSvgFiles = [];
  try {
    lobePngFiles = await readdir(lobePngDir);
    lobeSvgFiles = await readdir(lobeSvgDir);
  } catch (e) {
    console.warn("Lobe cache not found at /tmp/lobe_cache, skipping upstream copy.");
  }

  const inventory = [];

  for (const { id: brand, type } of allBrands) {
    const brandDir = resolve(catalogDir, brand);
    await mkdir(brandDir, { recursive: true });

    const lobeKey = lobeAlias[brand] || brand;

    // Check if upstream Lobe Icons has this asset
    const pngColorFile = `${lobeKey}-color.png`;
    const pngFile = `${lobeKey}.png`;
    const svgColorFile = `${lobeKey}-color.svg`;
    const svgIconFile = `${lobeKey}.svg`;
    const svgBrandFile = `${lobeKey}-brand.svg`;
    const svgTextFile = `${lobeKey}-text.svg`;

    let matchedLobe = false;

    // 1. App Icon PNG (Only for color icons, avoiding dark-mode white monochrome PNGs)
    if (lobePngFiles.includes(pngColorFile)) {
      await cp(resolve(lobePngDir, pngColorFile), resolve(brandDir, "app-icon.png"));
      matchedLobe = true;
    }

    // 2. Color SVG
    if (lobeSvgFiles.includes(svgColorFile)) {
      await cp(resolve(lobeSvgDir, svgColorFile), resolve(brandDir, "color.svg"));
      matchedLobe = true;
    }

    // 3. Icon SVG
    if (lobeSvgFiles.includes(svgIconFile)) {
      await cp(resolve(lobeSvgDir, svgIconFile), resolve(brandDir, "icon.svg"));
      matchedLobe = true;
    }

    // 4. Logo SVG
    if (lobeSvgFiles.includes(svgBrandFile)) {
      await cp(resolve(lobeSvgDir, svgBrandFile), resolve(brandDir, "logo.svg"));
      matchedLobe = true;
    } else if (lobeSvgFiles.includes(svgTextFile)) {
      await cp(resolve(lobeSvgDir, svgTextFile), resolve(brandDir, "logo.svg"));
      matchedLobe = true;
    }

    // Inspect final state in local catalog
    const hasIcon = await fileExists(resolve(brandDir, "icon.svg"));
    const hasLogoSvg = await fileExists(resolve(brandDir, "logo.svg"));
    const hasLogoPng = await fileExists(resolve(brandDir, "logo.png"));
    const hasColor = await fileExists(resolve(brandDir, "color.svg"));
    const hasAppIcon = await fileExists(resolve(brandDir, "app-icon.png"));

    inventory.push({
      brand,
      type,
      matchedLobe,
      hasIcon,
      hasLogo: hasLogoSvg ? "logo.svg" : (hasLogoPng ? "logo.png" : null),
      hasColor,
      hasAppIcon
    });

    console.log(`[${matchedLobe ? "Lobe" : "Local"}] ${brand}: icon=${hasIcon}, color=${hasColor}, appIcon=${hasAppIcon}`);
  }

  // Generate BRAND_INVENTORY.md
  let md = `# Brand 资源清单（BRAND INVENTORY）\n\n`;
  md += `> 与 \`assets/brands/catalog/\` 实际文件保持一致。\n`;
  md += `> 命名模板：\`icon.svg\` 方形图标 · \`logo.svg\`/\`logo.png\` 横向完整 logo · \`color.svg\` 彩色矢量图标 · \`app-icon.png\` 官方/Lobe Icons 原版高清光栅图标。\n\n`;
  md += `共 **${inventory.length}** 个品牌：${catalog.agents.length} Agent + ${catalog.providers.length} Provider。\n\n`;
  md += `| # | Brand | 类型 | 来源 | icon | logo | color | app-icon |\n`;
  md += `|---|-------|------|:----:|:----:|:----:|:------:|:--------:|\n`;

  inventory.forEach((item, index) => {
    const num = index + 1;
    const src = item.matchedLobe ? "Lobe Icons" : "Local Source";
    const iconCol = item.hasIcon ? `<img src="catalog/${item.brand}/icon.svg" width="24">` : "—";
    const logoCol = item.hasLogo ? `<img src="catalog/${item.brand}/${item.hasLogo}" width="88">` : "—";
    const colorCol = item.hasColor ? `<img src="catalog/${item.brand}/color.svg" width="24">` : "—";
    const appIconCol = item.hasAppIcon ? `<img src="catalog/${item.brand}/app-icon.png" width="24">` : "—";
    md += `| ${num} | \`${item.brand}\` | ${item.type} | ${src} | ${iconCol} | ${logoCol} | ${colorCol} | ${appIconCol} |\n`;
  });

  md += `\n## 同步与使用规范\n\n`;
  md += `1. **优先使用 Lobe Icons 官方资源**：通过 \`scripts/sync_brand_assets_from_lobe.mjs\` 自动拉取 Lobe Icons 官方高清 PNG 与 SVG。\n`;
  md += `2. **本地 Fallback 机制**：Lobe Icons 未包含的独立品牌（如 \`reasonix\`）保留专属官方仓库资源。\n`;
  md += `3. **macOS AppKit 原生渲染**：统一优先加载 \`app-icon.png\`，杜绝 CoreSVG 渐变/遮罩裁剪问题。\n`;

  await writeFile(inventoryMdPath, md, "utf8");
  console.log("Updated BRAND_INVENTORY.md successfully.");

  // Sync to landing public/brand-assets
  await rm(landingDest, { recursive: true, force: true });
  await mkdir(dirname(landingDest), { recursive: true });
  await cp(catalogDir, landingDest, { recursive: true });
  console.log("Synced to landing/public/brand-assets.");

  // Sync to dist app bundle if present
  if (await fileExists(dirname(appBundleDest))) {
    await rm(appBundleDest, { recursive: true, force: true });
    await cp(catalogDir, appBundleDest, { recursive: true });
    console.log("Synced to built app bundle.");
  }
}

main().catch(err => {
  console.error("Sync failed:", err);
  process.exit(1);
});
