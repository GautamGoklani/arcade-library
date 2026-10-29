# Deploy — arcade-library

- **Production:** `main` → Vercel, which serves the repo root with no build (`vercel.json`).
- **Domain:** `library.gautamgoklani.com`. TODO(owner): confirm the domain is added to this
  repo's Vercel project with the DNS record Vercel asks for (a CNAME for `library`). GAP-2.
- **Previews:** every pushed branch gets a Vercel preview URL, if Git integration is on.
  TODO(owner): confirm.
- **Rollback:** promote the previous deployment in the Vercel dashboard, or revert the commit
  on `main`.
- **The portfolio side:** `next.config.ts` and `SITE.libraryUrl` in the `portfolio` repo hold
  this host. If it changes, change both.
