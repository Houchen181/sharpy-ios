// Free, keyless (or free-key) public sources. Each fetcher returns plain text the
// card writer can quote from; nothing here calls Claude.
import { USER_AGENT } from "./env";

export interface SourceDoc {
  /** Shown to Claude as [S<n>]. */
  label: string;
  title: string;
  url: string;
  publisher: string;
  text: string;
  imageURL?: string;
}

export interface Paper {
  title: string;
  abstract: string;
  url: string;
  venue: string;
  peerReviewed: boolean;
  date: string;
  authors: string;
}

const headers = { "User-Agent": USER_AGENT, Accept: "application/json" };

function pad(n: number) {
  return String(n).padStart(2, "0");
}

export function stripHtml(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&#8217;/g, "’")
    .replace(/&#8216;/g, "‘")
    .replace(/&#8220;/g, "“")
    .replace(/&#8221;/g, "”")
    .replace(/&#8211;/g, "–")
    .replace(/&#8212;/g, "—")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

interface WikiPage {
  titles?: { normalized?: string };
  extract?: string;
  content_urls?: { desktop?: { page?: string } };
  thumbnail?: { source?: string };
}

/** Wikipedia's featured feed: today's featured article and "On this day" events. */
export async function wikipediaFeatured(date: Date): Promise<SourceDoc[]> {
  const path = `${date.getUTCFullYear()}/${pad(date.getUTCMonth() + 1)}/${pad(date.getUTCDate())}`;
  const res = await fetch(`https://en.wikipedia.org/api/rest_v1/feed/featured/${path}`, { headers });
  if (!res.ok) throw new Error(`Wikipedia feed ${res.status}`);
  const feed = (await res.json()) as {
    tfa?: WikiPage;
    onthisday?: { text: string; year: number; pages?: WikiPage[] }[];
  };
  const docs: SourceDoc[] = [];
  if (feed.tfa?.extract && feed.tfa.content_urls?.desktop?.page) {
    const title = feed.tfa.titles?.normalized ?? "Today's featured article";
    docs.push({
      label: "featured_article",
      title,
      url: feed.tfa.content_urls.desktop.page,
      publisher: "Wikipedia",
      // The feed's extract is one sentence; the article's lead section has the substance.
      text: (await wikipediaIntro(title).catch(() => null)) || feed.tfa.extract,
      imageURL: feed.tfa.thumbnail?.source,
    });
  }
  for (const event of (feed.onthisday ?? []).slice(0, 6)) {
    const page = event.pages?.find((p) => p.extract && p.content_urls?.desktop?.page);
    if (!page) continue;
    docs.push({
      label: "on_this_day",
      title: `${event.year}: ${page.titles?.normalized ?? ""}`,
      url: page.content_urls!.desktop!.page!,
      publisher: "Wikipedia",
      text: `On this day in ${event.year}: ${event.text}\n\n${page.extract}`,
      imageURL: page.thumbnail?.source,
    });
  }
  return docs;
}

async function wikipediaIntro(title: string): Promise<string | null> {
  const params = new URLSearchParams({
    action: "query", prop: "extracts", exintro: "1", explaintext: "1", redirects: "1",
    format: "json", formatversion: "2", titles: title,
  });
  const res = await fetch(`https://en.wikipedia.org/w/api.php?${params}`, { headers });
  if (!res.ok) return null;
  const data = (await res.json()) as { query?: { pages?: { extract?: string }[] } };
  return data.query?.pages?.[0]?.extract?.trim() || null;
}

/** NASA's Astronomy Picture of the Day; the explanation is written by professional astronomers. */
export async function nasaApod(apiKey: string | undefined): Promise<SourceDoc | null> {
  const res = await fetch(`https://api.nasa.gov/planetary/apod?api_key=${apiKey || "DEMO_KEY"}&thumbs=true`, { headers });
  if (!res.ok) throw new Error(`APOD ${res.status}`);
  const apod = (await res.json()) as {
    title: string;
    explanation: string;
    date: string;
    media_type: string;
    url: string;
    thumbnail_url?: string;
    copyright?: string;
  };
  const [y, m, d] = apod.date.split("-");
  // Since APOD moved to science.nasa.gov the API sometimes returns the site's
  // name and logo instead of the picture; keep the (correct) explanation only.
  const broken = apod.title === "NASA Science" || /nasa-logo/.test(apod.url);
  const image = apod.media_type === "image" ? apod.url : apod.thumbnail_url;
  return {
    label: "space",
    title: broken ? "Astronomy Picture of the Day" : apod.title,
    url: `https://apod.nasa.gov/apod/ap${y.slice(2)}${m}${d}.html`,
    publisher: "NASA APOD",
    text: apod.explanation.split("Tomorrow's picture:")[0].replace(/\s+/g, " ").trim(),
    // Only show images NASA can share freely; credited photos stay a link.
    imageURL: broken || apod.copyright ? undefined : image,
  };
}

/** Latest Quanta Magazine stories (editorially independent, fact-checked science journalism). */
export async function quantaLatest(limit = 3): Promise<SourceDoc[]> {
  const res = await fetch("https://www.quantamagazine.org/feed/", { headers: { "User-Agent": USER_AGENT } });
  if (!res.ok) throw new Error(`Quanta feed ${res.status}`);
  const xml = await res.text();
  const docs: SourceDoc[] = [];
  for (const m of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const tag = (name: string) => stripHtml(m[1].match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1] ?? "");
    const title = tag("title");
    const link = tag("link");
    const text = tag("description");
    if (title && link && text) docs.push({ label: "worth_reading", title, url: link, publisher: "Quanta Magazine", text });
    if (docs.length >= limit) break;
  }
  return docs;
}

/** Newest arXiv preprints matching a topic (not peer reviewed; labelled as such). */
export async function arxivRecent(topic: string, limit = 8): Promise<Paper[]> {
  const q = encodeURIComponent(`all:"${topic.replace(/"/g, "")}"`);
  const res = await fetch(
    `https://export.arxiv.org/api/query?search_query=${q}&sortBy=submittedDate&sortOrder=descending&max_results=${limit}`,
    { headers: { "User-Agent": USER_AGENT } },
  );
  if (!res.ok) throw new Error(`arXiv ${res.status}`);
  const xml = await res.text();
  const papers: Paper[] = [];
  for (const m of xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)) {
    const tag = (name: string) => stripHtml(m[1].match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`))?.[1] ?? "");
    const authors = [...m[1].matchAll(/<name>([\s\S]*?)<\/name>/g)].map((a) => stripHtml(a[1]));
    const url = tag("id").replace(/^http:/, "https:");
    papers.push({
      title: tag("title"),
      abstract: tag("summary"),
      url,
      venue: "arXiv preprint",
      peerReviewed: false,
      date: tag("published").slice(0, 10),
      authors: authors.length > 3 ? `${authors.slice(0, 3).join(", ")} et al.` : authors.join(", "),
    });
  }
  return papers.filter((p) => p.title && p.abstract);
}

/** Recent journal articles with abstracts from Crossref (publisher-registered DOIs), most relevant first. */
export async function crossrefRecent(topic: string, limit = 10): Promise<Paper[]> {
  const since = new Date(Date.now() - 45 * 86_400_000).toISOString().slice(0, 10);
  const params = new URLSearchParams({
    query: topic,
    filter: `from-pub-date:${since},type:journal-article,has-abstract:true`,
    rows: String(limit),
    select: "DOI,title,abstract,container-title,published,author",
  });
  const res = await fetch(`https://api.crossref.org/works?${params}`, { headers });
  if (!res.ok) throw new Error(`Crossref ${res.status}`);
  const data = (await res.json()) as {
    message: {
      items: {
        DOI: string;
        title?: string[];
        abstract?: string;
        "container-title"?: string[];
        published?: { "date-parts"?: number[][] };
        author?: { given?: string; family?: string }[];
      }[];
    };
  };
  return data.message.items
    .map((w) => {
      const parts = w.published?.["date-parts"]?.[0] ?? [];
      const authors = (w.author ?? []).map((a) => [a.given, a.family].filter(Boolean).join(" ")).filter(Boolean);
      return {
        title: stripHtml(w.title?.[0] ?? ""),
        abstract: stripHtml(w.abstract ?? "").replace(/^Abstract\s*/i, ""),
        url: `https://doi.org/${w.DOI}`,
        venue: stripHtml(w["container-title"]?.[0] ?? "Journal article"),
        peerReviewed: true,
        date: parts.map((n, i) => (i ? pad(n) : String(n))).join("-"),
        authors: authors.length > 3 ? `${authors.slice(0, 3).join(", ")} et al.` : authors.join(", "),
      };
    })
    .filter((p) => p.title && p.abstract.length > 200);
}

/** Recent peer-reviewed journal articles from OpenAlex (needs a free API key), most relevant first. */
export async function openAlexRecent(topic: string, apiKey: string | undefined, limit = 8): Promise<Paper[]> {
  const since = new Date(Date.now() - 45 * 86_400_000).toISOString().slice(0, 10);
  const params = new URLSearchParams({
    search: topic,
    filter: `from_publication_date:${since},type:article,has_abstract:true,primary_location.source.type:journal`,
    "per-page": String(limit),
    select: "title,doi,publication_date,abstract_inverted_index,primary_location,authorships",
  });
  if (apiKey) params.set("api_key", apiKey);
  const res = await fetch(`https://api.openalex.org/works?${params}`, { headers });
  if (!res.ok) throw new Error(`OpenAlex ${res.status}`);
  const data = (await res.json()) as {
    results: {
      title: string | null;
      doi: string | null;
      publication_date: string;
      abstract_inverted_index: Record<string, number[]> | null;
      primary_location: { landing_page_url?: string | null; source?: { display_name?: string } | null } | null;
      authorships?: { author: { display_name: string } }[];
    }[];
  };
  return data.results
    .map((w) => {
      const words: string[] = [];
      for (const [word, positions] of Object.entries(w.abstract_inverted_index ?? {})) {
        for (const p of positions) words[p] = word;
      }
      const authors = (w.authorships ?? []).map((a) => a.author.display_name);
      return {
        title: stripHtml(w.title ?? ""),
        abstract: words.filter(Boolean).join(" "),
        url: w.doi ?? w.primary_location?.landing_page_url ?? "",
        venue: w.primary_location?.source?.display_name ?? "Journal article",
        peerReviewed: true,
        date: w.publication_date,
        authors: authors.length > 3 ? `${authors.slice(0, 3).join(", ")} et al.` : authors.join(", "),
      };
    })
    .filter((p) => p.title && p.abstract.length > 200 && p.url);
}
