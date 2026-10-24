// Server-rendered viewer pages. They carry the author's brand only: no Reel logo anywhere.
// Art direction « Halo »: warm neutrals, one accent (the author's player color), Instrument Sans for titles,
// and the signature playback bar, a slim pill with a round playhead.

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
@font-face{font-family:"Instrument Sans";src:url("/fonts/InstrumentSans.ttf") format("truetype");font-weight:400 700;font-display:swap}
:root{--accent:#E2703A;--canvas:#faf7f4;--surface:#fff;--inset:#f3eee9;--fg:#231c17;--muted:#7a6d64;--line:rgba(70,45,25,.10);--on-accent:#fff;
--display:"Instrument Sans",-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--canvas:#1c1815;--surface:#231e1a;--inset:#191512;--fg:#f3ede8;--muted:#a89a90;--line:rgba(255,235,220,.09);color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--canvas);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
button,input,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.logo{height:28px;width:auto;display:block}
.wordmark{font-family:var(--display);font-weight:700;letter-spacing:-.01em}
`;

// The player: native <video> without its controls, plus Halo's bar.
const PLAYER_CSS = `
.stage{position:relative;border-radius:14px;overflow:hidden;background:#000}
.stage video{width:100%;display:block;aspect-ratio:16/9;background:#000;cursor:pointer}
.overlay{position:absolute;inset:auto 0 64px 0;display:flex;justify-content:center;gap:8px;pointer-events:none}
.overlay a{pointer-events:auto;background:var(--accent);color:var(--on-accent);text-decoration:none;border-radius:999px;padding:6px 12px;font-size:13px;font-weight:600;box-shadow:0 4px 16px rgba(0,0,0,.25)}
.controls{position:absolute;inset:auto 0 0 0;display:flex;align-items:center;gap:12px;padding:28px 14px 12px;background:linear-gradient(transparent,rgba(0,0,0,.55));color:#fff;transition:opacity .2s}
.stage.playing:not(:hover) .controls{opacity:0}
.controls button{all:unset;cursor:pointer;display:grid;place-items:center;width:28px;height:28px;border-radius:50%}
.controls button:hover{background:rgba(255,255,255,.14)}
.controls button:focus-visible{outline:2px solid #fff}
.controls svg{width:16px;height:16px;fill:currentColor}
.time{font:600 12px/1 -apple-system,sans-serif;font-variant-numeric:tabular-nums;min-width:84px}
.speed{font:600 12px/1 -apple-system,sans-serif;width:auto!important;padding:0 6px;border-radius:999px!important}
.pill{position:relative;flex:1;height:22px;cursor:pointer;touch-action:none}
.pill .track,.pill .fill{position:absolute;left:0;top:50%;height:4px;margin-top:-2px;border-radius:2px}
.pill .track{right:0;background:rgba(255,255,255,.28)}
.pill .fill{background:var(--accent)}
.pill .head{position:absolute;top:50%;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 2px #fff}
.pill .mark{position:absolute;top:50%;width:2px;height:8px;margin-top:-4px;background:rgba(255,255,255,.7)}
@media (prefers-reduced-motion:reduce){.controls{transition:none}}
`;

const ICONS = {
  play: `<svg viewBox="0 0 16 16"><path d="M4 2.5v11l9-5.5z"/></svg>`,
  pause: `<svg viewBox="0 0 16 16"><path d="M3.5 2h3v12h-3zM9.5 2h3v12h-3z"/></svg>`,
  cc: `<svg viewBox="0 0 16 16"><path d="M2 3h12a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zm4.6 3.2a2 2 0 1 0 0 3.6l-.4-.9a1 1 0 1 1 0-1.8zm5 0a2 2 0 1 0 0 3.6l-.4-.9a1 1 0 1 1 0-1.8z"/></svg>`,
  full: `<svg viewBox="0 0 16 16"><path d="M2 2h4v1.5H3.5V6H2zm8 0h4v4h-1.5V3.5H10zM2 10h1.5v2.5H6V14H2zm10.5 0H14v4h-4v-1.5h2.5z"/></svg>`,
};

function player(video: VideoRow): string {
  const poster = video.has_thumbnail ? `poster="/v/${video.id}/thumbnail"` : "";
  const captions = video.captions ? `<track kind="captions" srclang="fr" label="Français" src="/v/${video.id}/captions.vtt">` : "";
  return `
  <div class="stage" id="stage">
    <video id="video" playsinline preload="metadata" ${poster}>
      <source src="/v/${video.id}/video" type="video/mp4">${captions}
    </video>
    <div id="overlay" class="overlay"></div>
    <div class="controls">
      <button id="play" aria-label="Lecture">${ICONS.play}</button>
      <div class="pill" id="pill" role="slider" aria-label="Position" tabindex="0"><span class="track"></span><span class="fill" id="fill"></span><span id="marks"></span><span class="head" id="head"></span></div>
      <span class="time" id="time">0:00 / 0:00</span>
      <button class="speed" id="speed" aria-label="Vitesse">1×</button>
      ${video.captions ? `<button id="cc" aria-label="Sous-titres">${ICONS.cc}</button>` : ""}
      <button id="full" aria-label="Plein écran">${ICONS.full}</button>
    </div>
  </div>`;
}

const HEAD = (title: string) => `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHTML(title)}</title>`;

export function playerPage(video: VideoRow, settings: Settings, embed: boolean): string {
  const data = {
    id: video.id,
    duration: video.duration,
    createdAt: video.created_at,
    chapters: JSON.parse(video.chapters || "[]"),
    links: JSON.parse(video.links || "[]"),
    cta: video.cta ? JSON.parse(video.cta) : null,
  };

  if (embed) {
    return `${HEAD(video.title)}<style>${BASE_CSS}body{background:#000}.stage{border-radius:0}.stage video{height:100vh;aspect-ratio:auto}${PLAYER_CSS}</style>
<style>:root{--accent:${settings.playerColor}}</style></head><body>${player(video)}
<script>const REEL=${inlineJSON(data)};${PLAYER_JS}</script></body></html>`;
  }

  return `${HEAD(video.title)}
<meta property="og:title" content="${escapeHTML(video.title)}">
${video.has_thumbnail ? `<meta property="og:image" content="/v/${video.id}/thumbnail">` : ""}
<style>${BASE_CSS}${PLAYER_CSS}
header{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:60px;padding:14px max(20px,env(safe-area-inset-right)) 14px max(20px,env(safe-area-inset-left))}
.badge{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:3px 10px}
main{max-width:1200px;margin:0 auto;padding:8px max(20px,env(safe-area-inset-left)) 40px;display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:28px}
@media (max-width:900px){main{grid-template-columns:1fr}}
h1{font-family:var(--display);font-size:24px;line-height:1.2;margin:0 0 4px;letter-spacing:-.015em;font-weight:600;text-wrap:balance}
.meta{color:var(--muted);font-size:13px}
.below{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:16px;margin-top:18px}
.reactions{display:flex;gap:6px;flex-wrap:wrap}
.reactions button{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:4px 10px;cursor:pointer;font-size:13px}
.reactions button:hover{border-color:var(--accent)}
.cta{display:inline-block;margin-top:16px;background:var(--accent);color:var(--on-accent);border-radius:10px;padding:10px 18px;text-decoration:none;font-weight:600}
.description{max-width:65ch;color:var(--fg)}
aside{display:grid;gap:16px;align-content:start}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:16px}
.panel h2{font-family:var(--display);font-size:13px;font-weight:600;letter-spacing:.02em;color:var(--muted);margin:0 0 10px}
.chapters{list-style:none;margin:0;padding:0;display:grid;gap:2px}
.chapters button{all:unset;cursor:pointer;display:flex;gap:10px;padding:6px 8px;border-radius:8px;width:calc(100% - 16px)}
.chapters button:hover,.chapters button.on{background:color-mix(in srgb,var(--accent) 13%,transparent)}
.t{font-variant-numeric:tabular-nums;color:var(--accent);font-size:13px;min-width:38px;text-decoration:none}
.comments{display:grid;gap:14px;margin:0 0 14px;padding:0;list-style:none;max-height:440px;overflow:auto}
.comments b{font-weight:600}.comments p{margin:2px 0 0}
.empty{color:var(--muted);font-size:13px;margin:0 0 12px}
form{display:grid;gap:8px}
input,textarea{width:100%;border:1px solid var(--line);background:var(--inset);border-radius:10px;padding:9px 11px}
textarea{min-height:68px;resize:vertical}
form button{justify-self:start;background:var(--accent);color:var(--on-accent);border:0;border-radius:10px;padding:8px 16px;font-weight:600;cursor:pointer}
.hint{font-size:12px;color:var(--muted);display:flex;align-items:center;gap:6px}
.hint input{width:auto;accent-color:var(--accent)}
.error{color:#c0362c;font-size:13px}
</style><style>:root{--accent:${settings.playerColor}}</style></head><body>
<header>${brand(settings)}${video.privacy === "password" ? `<span class="badge">Protégée par mot de passe</span>` : ""}</header>
<main>
  <section>
    ${player(video)}
    <div class="below">
      <div>
        <h1>${escapeHTML(video.title)}</h1>
        <div class="meta" id="meta"></div>
      </div>
      <div class="reactions" id="reactions" aria-label="Réagir">
        <button data-kind="thumbs" aria-label="Utile">👍 <span></span></button><button data-kind="heart" aria-label="J'adore">❤️ <span></span></button><button data-kind="clap" aria-label="Bravo">👏 <span></span></button><button data-kind="laugh" aria-label="Drôle">😄 <span></span></button><button data-kind="wow" aria-label="Surprenant">😮 <span></span></button>
      </div>
    </div>
    ${data.cta ? `<a class="cta" href="${escapeHTML(data.cta.url)}" target="_blank" rel="noopener">${escapeHTML(data.cta.label)}</a>` : ""}
    ${video.description ? `<p class="description">${escapeHTML(video.description)}</p>` : ""}
  </section>
  <aside>
    ${data.chapters.length ? `<div class="panel"><h2>Chapitres</h2><ul class="chapters" id="chapters"></ul></div>` : ""}
    <div class="panel">
      <h2>Commentaires</h2>
      <ul class="comments" id="comments"></ul>
      <p class="empty" id="no-comments">Sois le premier à réagir.</p>
      <form id="comment-form">
        <input id="comment-author" name="author" placeholder="Ton nom" autocomplete="name" required maxlength="60">
        <textarea id="comment-body" name="body" placeholder="Ton commentaire" required maxlength="2000"></textarea>
        <label class="hint"><input type="checkbox" id="comment-at" checked> Au moment <span id="comment-time">0:00</span></label>
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
  return `${HEAD("Vidéo protégée")}<meta name="robots" content="noindex"><style>${BASE_CSS}
body{min-height:100vh;display:grid;place-items:center;padding:16px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:26px;width:min(380px,100%);display:grid;gap:12px}
h1{font-family:var(--display);font-size:19px;font-weight:600;margin:0;letter-spacing:-.01em}p{margin:0;color:var(--muted)}
input{border:1px solid var(--line);background:var(--inset);border-radius:10px;padding:10px 11px;width:100%}
button{background:var(--accent);color:var(--on-accent);border:0;border-radius:10px;padding:10px 14px;font-weight:600;cursor:pointer}
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

// Shared by the page and the embed: Halo's controls, clickable links during their range, view tracking.
const PLAYER_JS = `
const video=document.getElementById("video"),stage=document.getElementById("stage"),overlay=document.getElementById("overlay");
const pill=document.getElementById("pill"),fill=document.getElementById("fill"),head=document.getElementById("head"),timeEl=document.getElementById("time");
const playBtn=document.getElementById("play");const ICON_PLAY=${JSON.stringify(ICONS.play)},ICON_PAUSE=${JSON.stringify(ICONS.pause)};
const fmt=s=>{s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+":"+String(s%60).padStart(2,"0")};
const dur=()=>video.duration&&isFinite(video.duration)?video.duration:REEL.duration;
function paint(){const d=dur()||1,p=Math.min(1,video.currentTime/d)*100;fill.style.width=p+"%";head.style.left=p+"%";timeEl.textContent=fmt(video.currentTime)+" / "+fmt(dur());pill.setAttribute("aria-valuenow",Math.round(p))}
function toggle(){video.paused?video.play():video.pause()}
playBtn.onclick=toggle;video.onclick=toggle;
video.addEventListener("play",()=>{stage.classList.add("playing");playBtn.innerHTML=ICON_PAUSE});
video.addEventListener("pause",()=>{stage.classList.remove("playing");playBtn.innerHTML=ICON_PLAY});
video.addEventListener("timeupdate",paint);video.addEventListener("loadedmetadata",()=>{paint();drawMarks()});
function seekAt(x){const r=pill.getBoundingClientRect();video.currentTime=Math.min(1,Math.max(0,(x-r.left)/r.width))*dur();paint()}
pill.addEventListener("pointerdown",e=>{pill.setPointerCapture(e.pointerId);seekAt(e.clientX);pill.onpointermove=m=>seekAt(m.clientX)});
pill.addEventListener("pointerup",()=>{pill.onpointermove=null});
pill.addEventListener("keydown",e=>{if(e.key==="ArrowRight")video.currentTime+=5;if(e.key==="ArrowLeft")video.currentTime-=5});
function drawMarks(){const m=document.getElementById("marks");m.replaceChildren(...REEL.chapters.filter(c=>c.time>0).map(c=>{const s=document.createElement("span");s.className="mark";s.style.left=(c.time/(dur()||1)*100)+"%";return s}))}
const speeds=[1,1.25,1.5,2],speedBtn=document.getElementById("speed");let si=0;
speedBtn.onclick=()=>{si=(si+1)%speeds.length;video.playbackRate=speeds[si];speedBtn.textContent=speeds[si]+"×"};
const cc=document.getElementById("cc");if(cc){const tr=()=>video.textTracks[0];cc.onclick=()=>{const t=tr();if(t)t.mode=t.mode==="showing"?"hidden":"showing";cc.style.opacity=t&&t.mode==="showing"?1:.6};cc.style.opacity=.6}
document.getElementById("full").onclick=()=>{document.fullscreenElement?document.exitFullscreen():stage.requestFullscreen&&stage.requestFullscreen()};
document.addEventListener("keydown",e=>{if(e.target.closest&&e.target.closest("input,textarea"))return;if(e.code==="Space"){e.preventDefault();toggle()}});
let shown="";
video.addEventListener("timeupdate",()=>{const t=video.currentTime;const active=REEL.links.filter(l=>t>=l.start&&t<=l.end);
const key=active.map(l=>l.url).join("|");if(key===shown)return;shown=key;overlay.replaceChildren(...active.map(l=>{const a=document.createElement("a");a.href=l.url;a.target="_blank";a.rel="noopener";a.textContent=l.label;return a}))});
const viewId=crypto.randomUUID();let best=0;let viewer="";try{viewer=localStorage.getItem("reel-name")||""}catch(e){}
function report(){const d=dur();if(!d)return;const p=Math.min(100,Math.round(video.currentTime/d*100));if(p<=best&&best>0)return;best=Math.max(best,p);
navigator.sendBeacon("/v/"+REEL.id+"/views",new Blob([JSON.stringify({view:viewId,viewer,percent:best})],{type:"application/json"}))}
video.addEventListener("play",report,{once:true});setInterval(()=>{if(!video.paused)report()},10000);
video.addEventListener("ended",report);addEventListener("pagehide",report);paint();
`;

const PAGE_JS = `
const meta=document.getElementById("meta");meta.textContent=new Date(REEL.createdAt).toLocaleDateString("fr-FR",{day:"numeric",month:"long",year:"numeric"})+(REEL.duration?" · "+fmt(REEL.duration):"");
const list=document.getElementById("chapters");
if(list){for(const c of REEL.chapters){const li=document.createElement("li");const b=document.createElement("button");b.innerHTML='<span class="t"></span><span></span>';
b.children[0].textContent=fmt(c.time);b.children[1].textContent=c.title;b.onclick=()=>{video.currentTime=c.time;video.play()};li.append(b);list.append(li)}
video.addEventListener("timeupdate",()=>{const t=video.currentTime;let i=-1;REEL.chapters.forEach((c,k)=>{if(t>=c.time)i=k});[...list.querySelectorAll("button")].forEach((b,k)=>b.classList.toggle("on",k===i))})}
const timeLabel=document.getElementById("comment-time");video.addEventListener("timeupdate",()=>timeLabel.textContent=fmt(video.currentTime));
const author=document.getElementById("comment-author");try{author.value=localStorage.getItem("reel-name")||""}catch(e){}
async function loadComments(){const r=await fetch("/v/"+REEL.id+"/comments");if(!r.ok)return;const {comments}=await r.json();const ul=document.getElementById("comments");
document.getElementById("no-comments").hidden=comments.length>0;
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
