// Lanza el workflow de ingesta de GitHub Actions cada 3 horas.
// El cron de GitHub se salta ejecuciones, así que Cloudflare hace de despertador puntual.
const WORKFLOW_URL =
  "https://api.github.com/repos/Marinasvv/msvillaverde-p3-precios-carburantes" +
  "/actions/workflows/ingesta_3h.yml/dispatches";

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(triggerWorkflow(env));
  },
};

async function triggerWorkflow(env) {
  const response = await fetch(WORKFLOW_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "carburantes-scheduler",
    },
    body: JSON.stringify({ ref: "main" }),
  });

  // El fallo queda visible en los registros del Worker.
  if (!response.ok) {
    throw new Error(`GitHub respondió ${response.status}: ${await response.text()}`);
  }
}
