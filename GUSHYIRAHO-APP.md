# Uko wshyiraho App yawe kuri Cloudflare (Kinyarwanda)

Iyi ni intambwe ku yindi. Kurikira uko ziri.

---

## Mbere y'ibindi: ibyo ukeneye

1. **Konti ya Cloudflare** (isanzwe ufite — ni yo ifite database).
2. **Node.js** kuri mudasobwa yawe (verisiyo ya LTS).
3. **Dosiye enye za app** (ziri muri `videoapp/`):
   - `wrangler.toml`
   - `src/index.js`
   - `public/index.html`
   - `README.md`

---

## INTAMBWE YA 1 — Fungura R2 (aho ividewo zibikwa)

Iki ni **wowe wenyine** ushobora gukora (kubera ko bisaba uburyo bwo kwishyura).

1. Injira kuri https://dash.cloudflare.com
2. Ku ruhande, kanda **R2**
3. Kanda **Enable R2** / **Purchase R2**
4. Ongeraho uburyo bwo kwishyura (ariko **ni ubuntu kugeza 10GB** — nta mafaranga bakwaka udashije kurenza)

R2 imaze gufungurwa, komeza ku ntambwe ikurikira.

---

## INTAMBWE YA 2 — Shyiraho Node.js na Wrangler

Fungura **Terminal** (cyangwa Command Prompt kuri Windows).

Andika izi komandi imwe imwe:

```
npm install -g wrangler
```

Iyi ishyiraho "wrangler" — igikoresho gishyiraho app kuri Cloudflare.

---

## INTAMBWE YA 3 — Injira muri Cloudflare

```
wrangler login
```

Bizafungura urupapuro rwa interineti — kanda **Allow** kugira ngo wemere.

---

## INTAMBWE YA 4 — Kora bucket ya R2

```
npx wrangler r2 bucket create video-app-media
```

Iyi ikora aho ividewo n'amafoto bizabikwa. **Izina rigomba kuba `video-app-media`** (nk'uko riri muri wrangler.toml).

---

## INTAMBWE YA 5 — Injira mu idosiye ya app

 Genda aho wabitse dosiye za app. Urugero:

```
cd videoapp
```

(Hindura `videoapp` ube ari aho dosiye zawe ziri.)

Reba ko dosiye ziri aho:
```
ls
```
Ugomba kubona: `wrangler.toml`, `src`, `public`, `README.md`

---

## INTAMBWE YA 6 — Shyiraho app!

```
npx wrangler deploy
```

Iyi ni yo ntambwe nkuru. Wrangler izashyiraho app yawe kuri Cloudflare.

Iyo birangiye, uzabona **URL** (nka `https://video-app.xxx.workers.dev`) —
iyo ni yo app yawe iri kuri interineti!

---

## Nyuma yo gushyiraho

- App yawe iraba iri kuri interineti kuri iyo URL.
- **Konti ya mbere** wiyandikishaho: kugira ngo ube admin, injira muri Settings
  → hasi → "Claim admin (first account only)". Iyi ikora **rimwe gusa** —
  konti ya mbere gusa ishobora kuba admin.

---

## Iyo washaka guhindura app nyuma

Buri gihe uhinduye code (cyangwa nkakugufasha kuyihindura),
usubiramo INTAMBWE YA 6 gusa:

```
npx wrangler deploy
```

Database (D1) isanzwe ihari — ntabwo ugomba kongera kuyikora.
Ni code gusa ihinduka.

---

## Ibibazo bikunze kugaragara

**"command not found: wrangler"**
→ Subiramo INTAMBWE YA 2 (`npm install -g wrangler`)

**"You need to enable R2"**
→ Subiramo INTAMBWE YA 1 (fungura R2 muri dashboard)

**"database not found"**
→ Reba ko uri mu idosiye nyayo (INTAMBWE YA 5), kandi ko wrangler.toml
   ifite database_id nyayo.

---

## Ibyo ugomba kumenya (ukuri)

- **Kwishyura mu bwoko bwa Mobile Money cyangwa ikarita**: app ifite sisitemu
  yo kwandika amafaranga (coins, gifts, earnings), ariko **ntabwo yohereza
  amafaranga koko**. Kugira ngo amafaranga agende koko, ukeneye kongeraho
  serivisi nka Stripe cyangwa Mobile Money API, hamwe n'ubucuruzi bwanditse.
  Ubu, "Mark paid" na kwemeza coins bibika gusa ko byakozwe — ntibyimura
  amafaranga.

- **R2** ni yo yonyine isigaye kugira ngo ividewo zibike. Utabifungura,
  app irakora ariko ntushobora kohereza ividewo.
