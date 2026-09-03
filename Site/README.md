# Perch landing page

`Site/index.html` is the self-contained public landing and download page.
It has no build step, no external fonts, no CDN, and no analytics, matching
the product's privacy posture. Chinese and English are maintained together in
the same file and toggled at runtime.

## Publish a release

1. Run `sh Scripts/build-beta.sh` and complete
   [the release checklist](../docs/RELEASE_CHECKLIST.md).
2. Open `Site/index.html` and fill the `PERCH_RELEASE` block near the bottom
   from `release-manifest.json`:
   - `version` — the released version, e.g. `0.5.4-beta.1`
   - `downloadUrl` — the published notarized ZIP URL
   - `sha256` — the ZIP checksum recorded in the manifest
3. Leaving `downloadUrl` empty keeps the download button in its disabled
   "coming soon" state; the page never links an unverified artifact.

## Distribution-gate coverage

The page states macOS 14+, Apple Silicon only, Beta status, the local-agent
lifecycle limitations, and the SHA-256 checksum, and links the privacy policy,
security policy, changelog, setup tutorials, removal guide, feedback channel
(GitHub Issues), and the private vulnerability-reporting channel (GitHub
security advisories), as required by section 4 of the release checklist.

## Local preview

```sh
open Site/index.html
# or
python3 -m http.server -d Site 8000
```

## Deploy

The page is static; any static host works. For GitHub Pages, publish the
`Site/` directory (for example via a Pages workflow or by serving the branch
root and linking `/Site/`). `assets/perch-icon-appicon.png` is copied from
`Packaging/perch-icon-appicon.png`; re-copy it if the app icon changes.

## SEO / GEO

- `index.html` carries canonical, Open Graph, Twitter card, theme-color, and
  JSON-LD structured data (`SoftwareApplication` + `FAQPage`).
- `robots.txt` welcomes all crawlers (including AI/LLM crawlers) and points to
  `sitemap.xml`; `llms.txt` gives generative engines a factual product summary.
- All absolute URLs assume the GitHub Pages origin
  `https://lttxzmj.github.io/Perch/`. If the site moves to a custom domain,
  update the URLs in `index.html` (canonical, og:url, og:image, twitter:image,
  JSON-LD), `robots.txt`, `sitemap.xml`, and `llms.txt` together.
- Keep the FAQ answers in `index.html` and the `FAQPage` JSON-LD in sync when
  editing FAQ content.
