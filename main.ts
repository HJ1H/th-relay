/**
 * tokenharbor.ai 海外中转 · Deno Deploy 版（$0 / 无信用卡 / 无域名）
 *
 * 为什么换掉 CF Pages：CF Pages/Workers 免费档选不了出口 colo——国内请求落地
 * 香港边缘（CF-RAY: ...-HKG），Worker 就在香港执行、从香港出口，而 tokenharbor
 * 的封锁名单明确包含 "Mainland China, Hong Kong and Macau"（403 region_blocked
 * 原文实测，2026-10-13）。Deno Deploy 出口在 GCP 美西（实测 server: deno/gcp-us-west4），
 * 不在封锁名单上。
 *
 * 免费档（已核实）：100 万请求/月、20GiB 出站/月、10h CPU/月，不需要信用卡。
 * 新版 Deno Deploy 控制台不再有浏览器 playground，必须从一个 GitHub 仓库部署：
 *
 *   1. GitHub 建一个仓库（public/private 都行），把本文件作为 main.ts 传到仓库根目录
 *   2. 打开 https://console.deno.com → 登录（GitHub 账号）→ 建一个 organization
 *   3. + New App → 选刚才的仓库 → App Config 里 Framework 选 "No Preset"、
 *      Runtime 选 "Dynamic"、Dynamic Entrypoint 填 "main.ts" → Create App
 *   4. 等 build 完成，拿到 https://<app名>.deno.dev（组织账号下可能是 <app>-<org>.deno.dev，
 *      以控制台显示的为准）
 *
 * 之后每次改代码：git push 即自动重新部署。
 */

const UPSTREAM = "https://tokenharbor.ai";

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);

  // 只放行 /v1/ 前缀，其余一律 404（避免变成开放代理）
  if (!url.pathname.startsWith("/v1/")) {
    return new Response("not found", { status: 404 });
  }

  // 网关自检：要求调用方带 tokenharbor 形态的 key，挡掉随手扫描
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer thk_")) {
    return Response.json(
      { error: { message: "gateway: tokenharbor key required", type: "unauthorized" } },
      { status: 401 },
    );
  }

  // 路径 + query 原样透传上游；流式响应天然支持（Deno.serve 不缓冲 body）
  return fetch(new URL(url.pathname + url.search, UPSTREAM), {
    method: req.method,
    headers: req.headers,
    body: ["GET", "HEAD"].includes(req.method) ? undefined : req.body,
    redirect: "manual",
  });
});
