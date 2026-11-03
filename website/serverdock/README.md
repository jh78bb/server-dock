# ServerDock product website

Static English-first product introduction with a Korean page.

Official site: [serverdock.papo.co.kr](https://serverdock.papo.co.kr/). Intended public repository: [jh78bb/server-dock](https://github.com/jh78bb/server-dock). CI-backed GitHub Releases are planned; Mac App Store distribution is an additional goal subject to validation. Update the page download/repository links for this destination before the next site publication.

- English: `index.html`
- Korean: `ko.html`
- Shared styles and progressive enhancement: `style.css`, `main.js`
- Local screenshots and app icon: `img/`
- Hosting destination: SiteHub site `serverdock`

No build, external CDN, fonts, or script dependencies are required. Run a local static server to preview. Upload changed text through SiteHub's file API and binaries through its upload API. Credentials are never stored in this directory.

Publishing and domain management are handled by the site owner in SiteHub. Repository URL and release-status changes in documentation are not automatically published to the live site.

Screenshot locales are intentionally separate: `*-en.png` are real English UI captures of a local demo workspace; `workspace.png`, `editor.png`, and `monitoring.png` retain the Korean UI. English social previews also use `workspace-en.png`.

The toolkit presents 36 cards: six core features and 30 more across files/editing, server operations, commands/automation, network/web tools, and connections/organization/security. Category links jump directly to each group. Additional bilingual copy is recorded in `../feature-catalog.json`. Inline Lucide icons retain their notice in `LUCIDE-LICENSE.txt`.

The real-work gallery takes priority over the feature catalog, with seven localized screenshots and links to original-sized images. The gallery topics cover common server workflows; English screenshots are newly captured from the local demo app, while Korean screenshots reuse the supplied project assets.

The gallery now combines a full-width featured workspace, two concise illustrated stories, and four screenshot cards. Native dialog previews retain original image links as a fallback; image dimensions are verified from the actual files.
