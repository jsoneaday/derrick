import { netFetch, httpBody, headlines, type HandleEvent, type HandleResult } from "derrick";

interface PluginParams {
  topic?: string;
  text?: string;
  max?: number;
  limit?: number;
}

const defaultPage = "https://www.foxnews.com";

function sectionPath(topic: string): string | undefined {
  switch (topic.toLowerCase()) {
    case "world": return "world";
    case "national":
    case "us": return "us";
    case "technology":
    case "tech": return "tech";
    case "business": return "business";
    case "science": return "science";
    case "sport":
    case "sports": return "sports";
    case "politics": return "politics";
    default: return undefined;
  }
}

export function handle(event: HandleEvent<PluginParams>): HandleResult {
  const topic = event.params?.topic ?? event.params?.text ?? "";
  const rawMax = event.params?.max ?? event.params?.limit ?? 8;
  const max = Math.min(20, Math.max(1, Math.floor(rawMax)));
  if (event.kind === "http_results") {
    const titles = pickHeadlines(headlines(httpBody(event), 40), max, topic);
    const heading = topic ? `Daily News — ${topic}` : "Daily News";
    const summary = titles.length > 0
      ? titles.map((title, index) => `${index + 1}. ${title}`).join("\n")
      : "No headlines parsed from the page.";
    return [
      { verb: "result.emit", title: heading, summary },
      { verb: "message.post", text: summary },
    ];
  }
  const path = topic ? sectionPath(topic) : undefined;
  const url = path ? `https://www.foxnews.com/${path}` : defaultPage;
  return netFetch({ url });
}

function pickHeadlines(all: string[], max: number, topic: string): string[] {
  const needle = topic.trim().toLowerCase();
  const known = Boolean(needle && sectionPath(needle));
  const filtered = !needle || known
    ? all
    : all.filter((title) => title.toLowerCase().includes(needle));
  return (filtered.length > 0 ? filtered : all).slice(0, max);
}
