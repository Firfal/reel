// Server-rendered viewer pages. They carry the author's brand only: no Reel logo anywhere.
// Styling is driven by CSS variables so the chosen art direction can be applied in one place.

import type { Settings, VideoRow } from "./store";

const escapeHTML = (value: string) =>
  value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);

/** JSON safe to inline in a <script> block. */
const inlineJSON = (value: unknown) => JSON.stringify(value).replace(/</g, "\\u003c");

function brand(settings: Settings): string {
  if (settings.hasLogo) {
    return `<img class="logo" src="/brand/logo?v=${settings.logoVersion}" alt="${escapeHTML(settings.companyName || "Logo")}">`;
  }
  return settings.companyName ? `<span class="wordmark">${escapeHTML(settings.companyName)}</span>` : "";
}

const BASE_CSS = `
:root{--accent:#24408F;--bg:#f7f7f5;--surface:#fff;--fg:#1c1d1f;--muted:#6a6c70;--line:#e4e4e0;--on-accent:#fff;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#141517;--surface:#1c1d20;--fg:#ececea;--muted:#9a9ca1;--line:#2d2e32;color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
a{color:var(--accent)}
button,input,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.logo{height:28px;width:auto;display:block}
.wordmark{font-weight:700;letter-spacing:-.01em}
`;

export function playerPage(video: VideoRow, settings: Settings, embed: boolean): string {
  const data = {
    id: video.id,
    duration: video.duration,
    chapters: JSON.parse(video.chapters || "[]"),
    links: JSON.parse(video.links || "[]"),
    cta: video.cta ? JSON.parse(video.cta) : null,
  };
  const date = new Date(video.created_at).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" });
  const poster = video.has_thumbnail ? `poster="/v/${video.id}/thumbnail"` : "";
  const captions = video.captions ? `<track kind="captions" srclang="fr" label="Français" src="/v/${video.id}/captions.vtt" default>` : "";

  const player = `
  <div class="stage">
    <video id="video" controls playsinline preload="metadata" ${poster}>
      <source src="/v/${video.id}/video" type="video/mp4">${captions}
    </video>
    <div id="overlay" class="overlay"></div>
  </div>`;

  if (embed) {
    return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(video.title)}</title><style>${BASE_CSS}
body{background:#000}.stage{position:relative}video{width:100%;height:100vh;display:block;background:#000}
${PLAYER_CSS}</style><style>:root{--accent:${settings.playerColor}}</style></head><body>${player}
<script>const REEL=${inlineJSON(data)};${PLAYER_JS}</script></body></html>`;
  }

  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(video.title)}</title>
<meta property="og:title" content="${escapeHTML(video.title)}">
${video.has_thumbnail ? `<meta property="og:image" content="/v/${video.id}/thumbnail">` : ""}
<style>${BASE_CSS}
header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px max(16px,env(safe-area-inset-right));border-bottom:1px solid var(--line);background:var(--surface)}
main{max-width:1180px;margin:0 auto;padding:24px max(16px,env(safe-area-inset-left));display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:24px}
@media (max-width:900px){main{grid-template-columns:1fr}}
h1{font-size:22px;line-height:1.25;margin:0 0 4px;letter-spacing:-.01em;text-wrap:balance}
.meta{color:var(--muted);font-size:13px}
.stage{position:relative;border-radius:12px;overflow:hidden;background:#000}
video{width:100%;display:block;aspect-ratio:16/9;background:#000}
.below{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px;margin-top:16px}
.reactions{display:flex;gap:6px;flex-wrap:wrap}
.reactions button{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:4px 10px;cursor:pointer;font-size:13px}
.cta{background:var(--accent);color:var(--on-accent);border-radius:8px;padding:9px 16px;text-decoration:none;font-weight:600}
aside{display:grid;gap:16px;align-content:start}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px}
.panel h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 8px}
.chapters{list-style:none;margin:0;padding:0;display:grid;gap:2px}
.chapters button{all:unset;cursor:pointer;display:flex;gap:10px;padding:5px 6px;border-radius:6px;width:calc(100% - 12px)}
.chapters button:hover,.chapters button.on{background:color-mix(in srgb,var(--accent) 12%,transparent)}
.t{font-variant-numeric:tabular-nums;color:var(--accent);font-size:13px;min-width:38px}
.comments{display:grid;gap:12px;margin:0 0 12px;padding:0;list-style:none;max-height:420px;overflow:auto}
.comments b{font-weight:600}.comments p{margin:2px 0 0}
form{display:grid;gap:8px}
input,textarea{width:100%;border:1px solid var(--line);background:var(--bg);border-radius:8px;padding:8px 10px}
textarea{min-height:64px;resize:vertical}
form button{justify-self:start;background:var(--accent);color:var(--on-accent);border:0;border-radius:8px;padding:8px 14px;font-weight:600;cursor:pointer}
.hint{font-size:12px;color:var(--muted)}
.error{color:#c0362c;font-size:13px}
${PLAYER_CSS}</style><style>:root{--accent:${settings.playerColor}}</style></head><body>
<header>${brand(settings)}<span class="meta">${video.privacy === "password" ? "Protégée par mot de passe" : ""}</span></header>
<main>
  <section>
    ${player}
    <div class="below">
      <div>
        <h1>${escapeHTML(video.title)}</h1>
        <div class="meta">${escapeHTML(date)}${video.duration ? ` · ${formatDuration(video.duration)}` : ""}</div>
      </div>
      <div class="reactions" id="reactions" aria-label="Réagir">
        <button data-kind="thumbs" aria-label="Utile">👍 <span></span></button><button data-kind="heart" aria-label="J'adore">❤️ <span></span></button><button data-kind="clap" aria-label="Bravo">👏 <span></span></button><button data-kind="laugh" aria-label="Drôle">😄 <span></span></button><button data-kind="wow" aria-label="Surprenant">😮 <span></span></button>
      </div>
    </div>
    ${data.cta ? `<p><a class="cta" href="${escapeHTML(data.cta.url)}" target="_blank" rel="noopener">${escapeHTML(data.cta.label)}</a></p>` : ""}
    ${video.description ? `<p>${escapeHTML(video.description)}</p>` : ""}
  </section>
  <aside>
    ${data.chapters.length ? `<div class="panel"><h2>Chapitres</h2><ul class="chapters" id="chapters"></ul></div>` : ""}
    <div class="panel">
      <h2>Commentaires</h2>
      <ul class="comments" id="comments"></ul>
      <form id="comment-form">
        <input id="comment-author" name="author" placeholder="Ton nom" autocomplete="name" required maxlength="60">
        <textarea id="comment-body" name="body" placeholder="Ton commentaire" required maxlength="2000"></textarea>
        <label class="hint"><input type="checkbox" id="comment-at" checked style="width:auto"> Au moment <span id="comment-time">0:00</span></label>
        <button type="submit">Commenter</button>
        <span class="error" id="comment-error" hidden></span>
      </form>
    </div>
  </aside>
</main>
<script>const REEL=${inlineJSON(data)};${PLAYER_JS}${PAGE_JS}</script>
</body></html>`;
}

export function passwordPage(video: VideoRow, settings: Settings, wrong: boolean, embed: boolean): string {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vidéo protégée</title><meta name="robots" content="noindex"><style>${BASE_CSS}
body{min-height:100vh;display:grid;place-items:center;padding:16px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:24px;width:min(380px,100%);display:grid;gap:12px}
h1{font-size:18px;margin:0}p{margin:0;color:var(--muted)}
input{border:1px solid var(--line);background:var(--bg);border-radius:8px;padding:9px 10px;width:100%}
button{background:var(--accent);color:var(--on-accent);border:0;border-radius:8px;padding:9px 14px;font-weight:600;cursor:pointer}
.error{color:#c0362c;font-size:13px}</style><style>:root{--accent:${settings.playerColor}}</style></head><body>
<form class="card" method="post" action="/${embed ? "embed" : "v"}/${video.id}/unlock">
  ${brand(settings)}
  <h1>${escapeHTML(video.title)}</h1>
  <p>Cette vidéo est protégée par un mot de passe.</p>
  <input id="password" type="password" name="password" placeholder="Mot de passe" autocomplete="current-password" required autofocus>
  ${wrong ? `<span class="error">Mot de passe incorrect. Réessaie ou demande-le à l'auteur.</span>` : ""}
  <button type="submit">Regarder</button>
</form></body></html>`;
}

function formatDuration(seconds: number): string {
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)} min ${String(total % 60).padStart(2, "0")}`;
}

const PLAYER_CSS = `
.overlay{position:absolute;inset:auto 0 56px 0;display:flex;justify-content:center;gap:8px;pointer-events:none}
.overlay a{pointer-events:auto;background:var(--accent);color:var(--on-accent);text-decoration:none;border-radius:999px;padding:6px 12px;font-size:13px;font-weight:600;box-shadow:0 4px 16px rgba(0,0,0,.25)}
`;

// Shared by the page and the embed: clickable links during their time range, and view tracking.
const PLAYER_JS = `
const video=document.getElementById("video");const overlay=document.getElementById("overlay");
const fmt=s=>{s=Math.max(0,Math.floor(s));return Math.floor(s/60)+":"+String(s%60).padStart(2,"0")};
let shown="";
video.addEventListener("timeupdate",()=>{const t=video.currentTime;const active=REEL.links.filter(l=>t>=l.start&&t<=l.end);
const key=active.map(l=>l.url).join("|");if(key===shown)return;shown=key;overlay.replaceChildren(...active.map(l=>{const a=document.createElement("a");a.href=l.url;a.target="_blank";a.rel="noopener";a.textContent=l.label;return a}))});
const viewId=crypto.randomUUID();let best=0;let viewer="";try{viewer=localStorage.getItem("reel-name")||""}catch(e){}
function report(){const d=video.duration||REEL.duration;if(!d)return;const p=Math.min(100,Math.round(video.currentTime/d*100));if(p<=best&&best>0)return;best=Math.max(best,p);
navigator.sendBeacon("/v/"+REEL.id+"/views",new Blob([JSON.stringify({view:viewId,viewer,percent:best})],{type:"application/json"}))}
video.addEventListener("play",report,{once:true});setInterval(()=>{if(!video.paused)report()},10000);
video.addEventListener("ended",report);addEventListener("pagehide",report);
`;

const PAGE_JS = `
const list=document.getElementById("chapters");
if(list){for(const c of REEL.chapters){const li=document.createElement("li");const b=document.createElement("button");b.innerHTML='<span class="t"></span><span></span>';
b.children[0].textContent=fmt(c.time);b.children[1].textContent=c.title;b.onclick=()=>{video.currentTime=c.time;video.play()};li.append(b);list.append(li)}
video.addEventListener("timeupdate",()=>{const t=video.currentTime;let i=-1;REEL.chapters.forEach((c,k)=>{if(t>=c.time)i=k});[...list.querySelectorAll("button")].forEach((b,k)=>b.classList.toggle("on",k===i))})}
const timeLabel=document.getElementById("comment-time");video.addEventListener("timeupdate",()=>timeLabel.textContent=fmt(video.currentTime));
const author=document.getElementById("comment-author");try{author.value=localStorage.getItem("reel-name")||""}catch(e){}
async function loadComments(){const r=await fetch("/v/"+REEL.id+"/comments");if(!r.ok)return;const {comments}=await r.json();const ul=document.getElementById("comments");
ul.replaceChildren(...comments.map(c=>{const li=document.createElement("li");const head=document.createElement("div");const b=document.createElement("b");b.textContent=c.author;head.append(b);
if(c.time!==null){const t=document.createElement("a");t.href="#";t.className="t";t.textContent=" "+fmt(c.time);t.onclick=e=>{e.preventDefault();video.currentTime=c.time;video.play()};head.append(t)}
const p=document.createElement("p");p.textContent=c.body;li.append(head,p);return li}))}
document.getElementById("comment-form").addEventListener("submit",async e=>{e.preventDefault();const err=document.getElementById("comment-error");err.hidden=true;
const body={author:author.value,body:document.getElementById("comment-body").value,time:document.getElementById("comment-at").checked?video.currentTime:""};
try{localStorage.setItem("reel-name",author.value)}catch(x){}
const r=await fetch("/v/"+REEL.id+"/comments",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
if(!r.ok){err.textContent=(await r.json().catch(()=>({}))).error||"Le commentaire n'est pas parti. Réessaie.";err.hidden=false;return}
document.getElementById("comment-body").value="";loadComments()});
async function loadReactions(){const r=await fetch("/v/"+REEL.id+"/reactions");if(!r.ok)return;const {reactions}=await r.json();
for(const b of document.querySelectorAll("#reactions button")){const n=reactions.find(x=>x.kind===b.dataset.kind);b.querySelector("span").textContent=n?n.count:""}}
for(const b of document.querySelectorAll("#reactions button"))b.onclick=async()=>{await fetch("/v/"+REEL.id+"/reactions",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({kind:b.dataset.kind,time:video.currentTime})});loadReactions()};
loadComments();loadReactions();
`;
