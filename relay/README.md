# Custom domain without moving your DNS

Cloudflare only serves a custom domain for a Worker when that domain's DNS is on Cloudflare.
To keep your DNS where it is (IONOS, OVH, GoDaddy…), put this relay on Netlify (free):

1. Replace `YOUR-WORKER.workers.dev` in `_redirects` with your server's address.
2. Drop this folder on https://app.netlify.com/drop, then make the project public.
3. In the project's Domain management, add your subdomain (for example `video.example.com`) and add
   the records Netlify asks for at your DNS provider: a TXT `subdomain-owner-verification` and a CNAME
   from the subdomain to the project's `netlify.app` address.
4. Once HTTPS is active, tell the server to give links on that address:
   `curl -X PUT -H "Authorization: Bearer $OWNER_TOKEN" -H "Content-Type: application/json" \
     -d '{"publicURL":"https://video.example.com"}' https://YOUR-WORKER.workers.dev/api/settings`

The workers.dev address keeps working, so links already sent stay valid.
