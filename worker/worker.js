// Cloudflare Worker for summon.naklitechie.com.
//
// It pulls the site from git: the pages are committed to NakliTechie/summon and
// built by GitHub Pages (naklitechie.github.io/summon/*). This Worker reverse-
// proxies that origin under the custom domain, so the product page (root) and the
// visual guide (/guide/) are served at summon.naklitechie.com, always current with
// main. Edit the pages in the repo, push, and Pages + this Worker reflect it.

const ORIGIN = "https://naklitechie.github.io/summon";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = ORIGIN + url.pathname + url.search;
    const upstream = await fetch(target, {
      cf: { cacheTtl: 60, cacheEverything: true },
      headers: { "user-agent": "summon-site-worker" },
    });
    const headers = new Headers(upstream.headers);
    headers.set("x-served-by", "summon-site-worker");
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};
