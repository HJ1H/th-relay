/**
 * th-relay · Deno Deploy 双上游中转（$0 / 无信用卡 / 无域名）
 *
 * 路由：
 *   GET/POST /v1/*    → https://tokenharbor.ai/v1/*      （需 Authorization: Bearer thk_…）
 *   GET/POST /zen/*   → https://opencode.ai/zen/*        （需 Authorization: Bearer oc_…）
 *   GET/POST /codex/* → https://chatgpt.com/backend-api/codex/*  （ChatGPT 订阅 OAuth token 原样透传）
 *   GET      /ip      → Deno 出口 IP（诊断用）
 *
 * /codex 是为 Codex 桌面端订阅态加的：ChatGPT OAuth token 只能用在
 * chatgpt.com/backend-api/codex，不能用在 api.openai.com/v1（后者要 API key 的
 * api.responses.write scope，OAuth token 没有，会 401）。Codex 配置里填
 * base_url = "https://<app>.deno.net/codex" + requires_openai_auth = true，
 * Codex 自动追加 /responses，请求到达 /codex/responses，这里剥掉 /codex 前缀
 * 转发到 chatgpt.com/backend-api/codex/responses。
 *
 * 为什么要 /zen：OpenCode Zen 的免费模型按出口 IP 计每日额度（429 FreeUsageLimitError，
 * Retry-After 到 UTC 00:00）。校园网是整栋楼共享一个 NAT 出口，额度被别人吃光就轮不到自己。
 * 走 Deno 边缘出口等于换一个 IP 去取额度，且不碰 OpenCode Go 的订阅额度（免费模型单价 $0）。
 *
 * 安全约束：
 *   - /zen 只放行免费模型（-free 后缀 + 官方 Free 列表里唯一不带后缀的 big-pickle），
 *     其它模型一律 403 —— 防止手滑把付费模型（扣 Go 订阅额度）打进来。
 *   - 中转不保存任何 key；Authorization 由调用方原样带来、原样透传给上游。
 *
 * 免费档（已核实）：100 万请求/月、20GiB 出站/月、10h CPU/月，不需要信用卡。
 * 新版 Deno Deploy 控制台不再有浏览器 playground，必须从一个 GitHub 仓库部署：
 *
 *   1. GitHub 建一个仓库（public/private 都行），把本文件作为 main.ts 传到仓库根目录
 *   2. 打开 https://console.deno.com → 登录（GitHub 账号）→ 建一个 organization
 *   3. + New App → 选刚才的仓库 → App Config 里 Framework 选 "No Preset"、
 *      Runtime 选 "Dynamic"、Dynamic Entrypoint 填 "main.ts" → Create App
 *   4. 等 build 完成，拿到生产入口 https://<app>.<org-slug>.deno.net
 *
 * 之后每次改代码：git push 即自动重新部署。
 */

const TOKENHARBOR = "https://tokenharbor.ai";
const OPENCODE_ZEN = "https://opencode.ai/zen";
const CHATGPT_CODEX = "https://chatgpt.com/backend-api/codex";

/** 官方 Free 列表里不带 -free 后缀的例外（Big Pickle，单价 $0） */
const FREE_MODEL_EXCEPTIONS = new Set(["big-pickle"]);

function isFreeModel(id: string): boolean {
  return id.endsWith("-free") || FREE_MODEL_EXCEPTIONS.has(id);
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

/** 只转发这些请求头，避免把 host/content-length 之类的端到端头带歪 */
function forwardHeaders(req: Request): Headers {
  const out = new Headers();
  for (const [k, v] of req.headers) {
    const key = k.toLowerCase();
    if (
      key === "host" || key === "content-length" || key === "connection" ||
      key === "accept-encoding"
    ) continue;
    out.set(k, v);
  }
  return out;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const path = url.pathname;

  // ── 诊断：Deno 边缘的出口 IP（OpenCode 看到的就是它）───────────────
  if (path === "/ip") {
    try {
      const r = await fetch("https://api.ipify.org?format=json", {
        signal: AbortSignal.timeout(5000),
      });
      const ip = await r.json() as { ip?: string };
      return json({ egressIp: ip.ip ?? null, via: "deno-deploy" });
    } catch (e) {
      return json({ egressIp: null, error: String(e) }, 502);
    }
  }

  // ── 上游 1：tokenharbor（原有线路，行为不变）────────────────────────
  if (path.startsWith("/v1/")) {
    const auth = req.headers.get("Authorization") || "";
    if (!auth.startsWith("Bearer thk_")) {
      return json(
        { error: { message: "gateway: tokenharbor key required", type: "unauthorized" } },
        401,
      );
    }
    return fetch(new URL(path + url.search, TOKENHARBOR), {
      method: req.method,
      headers: forwardHeaders(req),
      body: ["GET", "HEAD"].includes(req.method) ? undefined : req.body,
      redirect: "manual",
    });
  }

  // ── 上游 2：OpenCode Zen（只放行免费模型）───────────────────────────
  if (path.startsWith("/zen/")) {
    const auth = req.headers.get("Authorization") || "";
    if (!auth.startsWith("Bearer oc_")) {
      return json(
        {
          error: {
            message: "gateway: opencode key required (Authorization: Bearer oc_...)",
            type: "unauthorized",
          },
        },
        401,
      );
    }

    // 付费模型拦截：只有 POST 带 body 的请求需要验 model
    let body: string | undefined;
    if (!["GET", "HEAD"].includes(req.method)) {
      body = await req.text();
      let model = "";
      try {
        model = String((JSON.parse(body) as { model?: unknown }).model ?? "");
      } catch {
        return json(
          { error: { message: "gateway: request body must be JSON", type: "invalid_request" } },
          400,
        );
      }
      if (model && !isFreeModel(model)) {
        return json(
          {
            error: {
              message:
                `gateway: model "${model}" is not a free model. This relay only allows ` +
                `*-free models (plus big-pickle) so your OpenCode Go quota is never touched.`,
              type: "model_not_allowed",
            },
          },
          403,
        );
      }
    }

    return fetch(new URL(OPENCODE_ZEN + path.slice("/zen".length) + url.search), {
      method: req.method,
      headers: forwardHeaders(req),
      body,
      redirect: "manual",
    });
  }

  // ── 上游 3：ChatGPT 订阅 / Codex（OAuth token 原样透传）────────────
  // Codex 的 requires_openai_auth=true 会把订阅 OAuth token 放在 Authorization。
  // 这里不校验 token 形态（eyJ… / sk-… 都放行），由上游 chatgpt.com 自己判。
  // 不保存、不改写任何凭证；SSE 流通过 req.body 原样转发。
  if (path === "/codex" || path.startsWith("/codex/")) {
    const auth = req.headers.get("Authorization") || "";
    if (!auth) {
      return json(
        { error: { message: "gateway: Authorization required for /codex", type: "unauthorized" } },
        401,
      );
    }
    const tail = path.slice("/codex".length) || "/";
    const upstream = new URL(CHATGPT_CODEX + tail + url.search);
    return fetch(upstream, {
      method: req.method,
      headers: forwardHeaders(req),
      body: ["GET", "HEAD"].includes(req.method) ? undefined : req.body,
      redirect: "manual",
    });
  }

  return new Response("not found", { status: 404 });
});
