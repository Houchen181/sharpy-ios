// The only sites Claude may search when writing quiz items and field primers.
// Subdomains are included (nih.gov covers ncbi.nlm.nih.gov). The API caps the list at 64.
export const TRUSTED_DOMAINS = [
  // Reference works
  "wikipedia.org", "britannica.com", "stanford.edu", "nobelprize.org", "loc.gov", "si.edu",
  // Journals and publishers
  "nature.com", "science.org", "cell.com", "pnas.org", "thelancet.com", "nejm.org", "bmj.com",
  "jamanetwork.com", "plos.org", "royalsocietypublishing.org", "aps.org", "iop.org", "acs.org",
  "rsc.org", "springer.com", "sciencedirect.com", "arxiv.org", "cochranelibrary.com",
  // Government and intergovernmental
  "nih.gov", "medlineplus.gov", "cdc.gov", "who.int", "nasa.gov", "noaa.gov", "nist.gov",
  "ipcc.ch", "un.org", "worldbank.org", "imf.org", "oecd.org", "federalreserve.gov", "bls.gov",
  "sec.gov", "europa.eu", "congress.gov",
  // Universities and open textbooks
  "mit.edu", "harvard.edu", "berkeley.edu", "ox.ac.uk", "cam.ac.uk", "khanacademy.org",
  "libretexts.org", "openstax.org",
  // Science journalism with editorial fact-checking
  "quantamagazine.org", "scientificamerican.com", "sciencenews.org", "newscientist.com",
  // Official technical documentation and standards bodies
  "developer.mozilla.org", "python.org", "developer.apple.com", "learn.microsoft.com", "w3.org",
  "ietf.org", "acm.org", "ieee.org",
  // Law and medicine
  "law.cornell.edu", "mayoclinic.org",
];

const PUBLISHERS: Record<string, string> = {
  "wikipedia.org": "Wikipedia", "britannica.com": "Britannica", "plato.stanford.edu": "Stanford Encyclopedia of Philosophy",
  "stanford.edu": "Stanford University", "nobelprize.org": "Nobel Prize", "loc.gov": "Library of Congress",
  "si.edu": "Smithsonian", "nature.com": "Nature", "science.org": "Science", "cell.com": "Cell Press",
  "pnas.org": "PNAS", "thelancet.com": "The Lancet", "nejm.org": "NEJM", "bmj.com": "The BMJ",
  "jamanetwork.com": "JAMA Network", "plos.org": "PLOS", "royalsocietypublishing.org": "Royal Society",
  "aps.org": "American Physical Society", "iop.org": "IOP Publishing", "acs.org": "American Chemical Society",
  "rsc.org": "Royal Society of Chemistry", "springer.com": "Springer", "sciencedirect.com": "ScienceDirect",
  "arxiv.org": "arXiv", "cochranelibrary.com": "Cochrane Library", "nih.gov": "NIH", "ncbi.nlm.nih.gov": "NCBI (NIH)",
  "medlineplus.gov": "MedlinePlus", "cdc.gov": "CDC", "who.int": "WHO", "nasa.gov": "NASA", "noaa.gov": "NOAA",
  "nist.gov": "NIST", "ipcc.ch": "IPCC", "un.org": "United Nations", "worldbank.org": "World Bank", "imf.org": "IMF",
  "oecd.org": "OECD", "federalreserve.gov": "Federal Reserve", "bls.gov": "U.S. Bureau of Labor Statistics",
  "sec.gov": "U.S. SEC", "europa.eu": "European Union", "congress.gov": "Congress.gov", "mit.edu": "MIT",
  "harvard.edu": "Harvard University", "berkeley.edu": "UC Berkeley", "ox.ac.uk": "University of Oxford",
  "cam.ac.uk": "University of Cambridge", "khanacademy.org": "Khan Academy", "libretexts.org": "LibreTexts",
  "openstax.org": "OpenStax", "quantamagazine.org": "Quanta Magazine", "scientificamerican.com": "Scientific American",
  "sciencenews.org": "Science News", "newscientist.com": "New Scientist", "developer.mozilla.org": "MDN Web Docs",
  "python.org": "Python.org", "developer.apple.com": "Apple Developer", "learn.microsoft.com": "Microsoft Learn",
  "w3.org": "W3C", "ietf.org": "IETF", "acm.org": "ACM", "ieee.org": "IEEE", "law.cornell.edu": "Cornell LII",
  "mayoclinic.org": "Mayo Clinic", "openalex.org": "OpenAlex", "doi.org": "DOI",
};

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function isTrusted(url: string): boolean {
  const host = hostOf(url);
  return TRUSTED_DOMAINS.some((d) => host === d || host.endsWith("." + d));
}

/** Friendly publisher name for a URL, matching the most specific known domain. */
export function publisherFor(url: string): string {
  const host = hostOf(url);
  const parts = host.split(".");
  for (let i = 0; i < parts.length - 1; i++) {
    const name = PUBLISHERS[parts.slice(i).join(".")];
    if (name) return name;
  }
  return host;
}
