import { For, Show, createSignal, onSettled } from "solid-js";
import type { JSX } from "@solidjs/web";
import { DemoVideo } from "./components/DemoVideo";
import { HeroPixelBackground } from "./components/HeroPixelBackground";
import { AppleIcon, BrandMark, MoonIcon, SunIcon } from "./components/Icons";
import { ToolPreview } from "./components/ToolPreview";
import { getLatestDownload, releasesUrl, type LatestDownload } from "./data/latest-release";
import { faqs, tools } from "./data/site";

const buttonClass =
  "group pressable relative inline-flex min-h-12 items-center justify-center gap-2.5 whitespace-nowrap rounded-full px-6 text-sm font-semibold tracking-tight transition duration-200 ease-out select-none bg-neutral-950 text-white shadow-[0_1px_2px_0_rgba(0,0,0,0.12),0_4px_12px_0_rgba(0,0,0,0.18),inset_0_0_0_1px_rgba(255,255,255,0.08)] hover:bg-neutral-900 before:pointer-events-none before:absolute before:inset-0 before:rounded-[inherit] before:p-px before:bg-gradient-to-b before:from-white/30 before:to-transparent before:[mask-clip:content-box,border-box] before:[mask-composite:exclude] before:[mask-image:linear-gradient(#fff_0_0),linear-gradient(#fff_0_0)] after:pointer-events-none after:absolute after:inset-0 after:rounded-[inherit] after:bg-gradient-to-b after:from-white after:to-transparent after:opacity-[0.14] after:transition after:duration-200 after:ease-out hover:after:opacity-[0.24] dark:bg-neutral-100 dark:text-neutral-950 dark:hover:bg-white dark:shadow-[0_1px_2px_0_rgba(0,0,0,0.5),0_6px_20px_0_rgba(0,0,0,0.4),inset_0_0_0_1px_rgba(255,255,255,0.2)] dark:before:from-white/60 dark:after:from-white dark:after:opacity-[0.22] dark:hover:after:opacity-[0.34]";

const navigation = [
  ["Demo", "#demo"],
  ["Tools", "#tools"],
  ["FAQ", "#faq"],
] as const;

const homeUrl = import.meta.env.BASE_URL;
const [latestDownload, setLatestDownload] = createSignal<LatestDownload>();
function downloadUrl() {
  const download = latestDownload();
  return download?.status === "available" ? download.url : undefined;
}

function DownloadLink(props: { placement: "header" | "hero" | "download-section"; id?: string; class: string; children: JSX.Element }) {
  return (
    <a
      id={props.id}
      class={props.class}
      href={downloadUrl() ?? "#download"}
      data-umami-event={downloadUrl() ? "download_click" : "download_interest"}
      data-umami-event-placement={props.placement}
    >
      {props.children}
    </a>
  );
}

export function SiteHeader(props: { home: boolean }) {
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");
  const [dark, setDark] = createSignal(document.documentElement.classList.contains("dark"));
  const [showNavCta, setShowNavCta] = createSignal(false);
  let followsSystem = true;
  try {
    followsSystem = !localStorage.getItem("lenotch-theme");
  } catch {
    // Theme preferences are optional when storage is blocked.
  }

  const applyTheme = (next: boolean) => {
    document.documentElement.classList.toggle("dark", next);
    setDark(next);
  };

  onSettled(() => {
    const onSystemChange = (event: MediaQueryListEvent) => {
      if (followsSystem) applyTheme(event.matches);
    };
    systemTheme.addEventListener("change", onSystemChange);

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() !== "d") return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.tagName === "SELECT" ||
          target.isContentEditable)
      ) {
        return;
      }
      toggleTheme();
    };
    window.addEventListener("keydown", onKeyDown);

    const checkVisibility = () => {
      const heroBtn = document.getElementById("hero-download-btn");
      setShowNavCta(!!heroBtn && heroBtn.getBoundingClientRect().bottom < 60);
    };

    checkVisibility();
    window.addEventListener("scroll", checkVisibility, { passive: true });
    window.addEventListener("resize", checkVisibility, { passive: true });

    return () => {
      systemTheme.removeEventListener("change", onSystemChange);
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("scroll", checkVisibility);
      window.removeEventListener("resize", checkVisibility);
    };
  });

  const toggleTheme = () => {
    const next = !dark();
    followsSystem = false;
    applyTheme(next);
    try {
      localStorage.setItem("lenotch-theme", next ? "dark" : "light");
    } catch {
      // The selected theme still applies to the current page.
    }
  };

  return (
      <header class="sticky top-3 z-30 mx-auto mt-3 w-[calc(100%_-_1.5rem)] max-w-4xl sm:top-5 sm:mt-5 sm:w-[calc(100%_-_3rem)]">
        <div class="flex min-h-[50px] items-center justify-between gap-3 rounded-[16px] border border-black/[0.08] bg-well/90 px-2.5 py-1 shadow-[inset_0_1.5px_4px_rgba(20,16,40,0.08),inset_0_0_0_1px_rgba(33,27,55,0.04),0_1px_0_rgba(255,255,255,0.7)] backdrop-blur-xl dark:border-black/50 dark:bg-[#121117]/90 dark:shadow-[inset_0_2px_6px_rgba(0,0,0,0.55),inset_0_0_0_1px_rgba(0,0,0,0.4),0_1px_0_rgba(255,255,255,0.05)]">
          <a href={props.home ? "#top" : homeUrl} class="inline-flex shrink-0 items-center gap-2 text-[15px] font-semibold tracking-[-0.035em]">
            <BrandMark class="size-7" />
            LeNotch
          </a>

          <div class="flex items-center gap-1.5 sm:gap-2">
            <nav aria-label="Sections" class="hidden items-center gap-0.5 text-[13px] font-medium md:flex">
              <For each={navigation}>
                {([label, href]) => (
                  <a href={props.home ? href : homeUrl + href} class="rounded-lg px-3 py-1.5 text-neutral-600 transition-colors hover:bg-well hover:text-neutral-950 dark:text-neutral-300 dark:hover:bg-well-dark dark:hover:text-white">
                    {label}
                  </a>
                )}
              </For>
            </nav>

            <details
              class="group relative md:hidden"
              onKeyDown={(event) => {
                if (event.key === "Escape" && event.currentTarget.open) {
                  event.currentTarget.open = false;
                  event.currentTarget.querySelector("summary")?.focus();
                }
              }}
            >
              <summary aria-label="Menu" class="pressable flex size-8 cursor-pointer list-none items-center justify-center rounded-[10px] border border-black/8 bg-surface text-neutral-700 shadow-[0_1px_2px_rgba(0,0,0,0.05)] hover:bg-neutral-100 hover:text-neutral-950 group-open:bg-neutral-100 dark:border-white/10 dark:bg-surface-dark dark:text-neutral-300 dark:shadow-[0_1px_2px_rgba(0,0,0,0.5)] dark:hover:bg-neutral-800 dark:hover:text-white dark:group-open:bg-neutral-800 [&::-webkit-details-marker]:hidden">
                <svg viewBox="0 0 24 24" class="size-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true">
                  <path d="M5 9h14M5 15h14" />
                </svg>
              </summary>
              <nav aria-label="Sections" class="absolute top-11 -right-12 z-20 grid w-44 rounded-2xl border border-black/10 bg-surface p-1.5 text-sm font-medium shadow-xl sm:-right-14 dark:border-white/10 dark:bg-surface-dark">
                <For each={navigation}>
                  {([label, href]) => (
                    <a href={props.home ? href : homeUrl + href} onClick={(event) => event.currentTarget.closest("details")?.removeAttribute("open")} class="rounded-xl px-3 py-2 hover:bg-well dark:hover:bg-well-dark">
                      {label}
                    </a>
                  )}
                </For>
              </nav>
            </details>

            <div
              hidden={!props.home}
              inert={!showNavCta()}
              class={`overflow-hidden transition-all duration-300 ease-[cubic-bezier(0.23,1,0.32,1)] ${
                showNavCta()
                  ? "max-w-[140px] opacity-100 translate-x-0"
                  : "max-w-0 opacity-0 translate-x-3 pointer-events-none"
              }`}
            >
              <DownloadLink
                placement="header"
                class="pressable inline-flex h-8 items-center justify-center gap-1.5 whitespace-nowrap rounded-[10px] border border-black/10 bg-neutral-950 px-3 text-xs font-semibold text-white shadow-[0_1px_2px_rgba(0,0,0,0.06)] hover:bg-neutral-800 dark:border-white/15 dark:bg-white dark:text-neutral-950 dark:shadow-[0_1px_2px_rgba(0,0,0,0.3)] dark:hover:bg-neutral-100"
              >
                <AppleIcon class="h-3.5 w-auto shrink-0" />
                <span>Download</span>
              </DownloadLink>
            </div>

            <button
              type="button"
              onClick={toggleTheme}
              title={dark() ? "Switch to light mode (D)" : "Switch to dark mode (D)"}
              aria-label={dark() ? "Switch to light mode (D)" : "Switch to dark mode (D)"}
              class="pressable flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-[10px] border border-black/8 bg-surface text-neutral-700 shadow-[0_1px_2px_rgba(0,0,0,0.05)] hover:bg-neutral-100 hover:text-neutral-950 dark:border-white/10 dark:bg-surface-dark dark:text-neutral-300 dark:shadow-[0_1px_2px_rgba(0,0,0,0.5)] dark:hover:bg-neutral-800 dark:hover:text-white"
            >
              <Show when={dark()} fallback={<MoonIcon class="size-4" />}>
                <SunIcon class="size-4" />
              </Show>
            </button>
          </div>
        </div>
      </header>
  );
}

export default function App() {
  onSettled(() => { void getLatestDownload().then(setLatestDownload); });
  return (
      <main class="w-full">
        {/* Full-bleed hero section edge-to-edge */}
        <section
          aria-labelledby="hero-title"
          class="relative isolate w-full overflow-hidden border-b border-black/10 pt-20 pb-24 sm:pt-32 sm:pb-32 md:pt-40 lg:pt-48 lg:pb-40 dark:border-white/12"
        >
          <HeroPixelBackground />

          <div class="mx-auto max-w-6xl px-5 text-center sm:px-8">
            <h1
              id="hero-title"
              class="hero-blur-in hero-delay-1 text-[clamp(3rem,8.9vw,7.25rem)] leading-[.96] font-extralight tracking-[-0.06em]"
            >
              <span class="block -mb-[0.08em] bg-gradient-to-b from-[#111110] via-[#221d1a] to-[#574942] bg-clip-text pb-[0.08em] text-[#111110] [-webkit-text-fill-color:transparent] dark:from-white dark:via-accent-cream dark:to-[#f3cba0] dark:text-accent-cream">
                Your Mac's notch.
              </span>
              <span class="block -mb-[0.08em] bg-gradient-to-r from-[#ff8a1e] via-accent to-[#c82d00] bg-clip-text pb-[0.08em] text-accent [-webkit-text-fill-color:transparent] dark:from-accent-amber dark:via-accent-tangerine dark:to-accent">
                Now useful.
              </span>
            </h1>
            <p class="hero-blur-in hero-delay-2 mx-auto mt-6 max-w-sm text-base leading-relaxed text-balance text-neutral-600 sm:mt-8 sm:max-w-lg sm:text-lg dark:text-neutral-300">
              Control your music, chat with AI, and keep everyday tools at the top of your screen.
            </p>
            <div class="hero-blur-in hero-delay-3 mt-8 sm:mt-10">
              <DownloadLink
                id="hero-download-btn"
                placement="hero"
                class={buttonClass}
              >
                <AppleIcon class="relative z-10 h-[17px] w-auto shrink-0" />
                <span class="relative z-10">Download for macOS</span>
              </DownloadLink>
            </div>

            <div class="hero-blur-in hero-delay-4 mt-20 sm:mt-28 lg:mt-36">
              <DemoVideo />
            </div>
          </div>
        </section>

        {/* Content sections constrained to max-w-6xl */}
        <div class="mx-auto max-w-6xl px-5 sm:px-8">

        <section id="tools" aria-labelledby="tools-title" class="py-19 sm:py-27">
          <h2 id="tools-title" class="text-4xl leading-none font-extralight tracking-[-0.05em] sm:text-5xl lg:text-6xl">What’s in the notch</h2>
          <ul class="mt-8 grid grid-cols-1 gap-x-5 gap-y-8 sm:mt-11 sm:grid-cols-2 sm:gap-y-12 lg:grid-cols-3">
            <For each={tools}>
              {(tool) => (
                <li class="min-w-0">
                  <article aria-labelledby={`${tool.id}-title`}>
                    <ToolPreview tool={tool} />
                    <div class="px-0.5 pt-4">
                      <h3 id={`${tool.id}-title`} class="text-lg font-semibold tracking-[-0.035em]">{tool.name}</h3>
                      <p class="mt-0.5 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">{tool.description}</p>
                    </div>
                  </article>
                </li>
              )}
            </For>
          </ul>
        </section>

        <section id="faq" aria-labelledby="faq-title" class="grid gap-7 border-y border-black/10 py-16 sm:grid-cols-2 sm:gap-12 sm:py-22 dark:border-white/12">
          <h2 id="faq-title" class="text-4xl leading-none font-extralight tracking-[-0.05em] sm:text-5xl">FAQ</h2>
          <div class="divide-y divide-black/10 dark:divide-white/12">
            <For each={faqs}>
              {(item) => (
                <details class="group">
                  <summary class="flex min-h-13 cursor-pointer list-none items-center justify-between gap-3 py-3 text-left text-sm font-semibold [&::-webkit-details-marker]:hidden">
                    {item.question}
                    <svg class="size-4 shrink-0 text-neutral-500 group-open:rotate-45 dark:text-neutral-400" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
                      <path d="M3 8h10M8 3v10" />
                    </svg>
                  </summary>
                  <p class="pb-4 pr-5 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">{item.answer}</p>
                </details>
              )}
            </For>
          </div>
        </section>

        <section id="download" aria-labelledby="download-title" class="px-2 py-21 text-center sm:py-28">
          <BrandMark class="mx-auto size-24 sm:size-28" />
          <h2 id="download-title" class="mt-6 text-4xl leading-none font-extralight tracking-[-0.05em] sm:text-5xl">LeNotch for Mac</h2>
          <p class="mt-3 text-sm text-neutral-600 dark:text-neutral-400">macOS 15+ · Apple silicon and Intel</p>
          <div aria-live="polite" class="mt-6 text-sm font-semibold">
            <Show when={downloadUrl()} fallback={
              <p>{latestDownload()?.status === "unavailable" ? (
                <>Couldn’t check for a download. <a class="underline" href={releasesUrl} data-umami-event="releases_click" data-umami-event-placement="download-section">Check GitHub Releases</a></>
              ) : latestDownload() ? "Download coming soon" : "Checking for a download…"}</p>
            }>
              <DownloadLink placement="download-section" class={buttonClass}>
                <AppleIcon class="relative z-10 h-[17px] w-auto shrink-0" />
                <span class="relative z-10">Download for macOS</span>
              </DownloadLink>
            </Show>
          </div>
        </section>
        </div>
      </main>
  );
}

export function SiteFooter(props: { home: boolean }) {
  const linkClass = "inline-flex min-h-10 items-center text-neutral-600 hover:text-neutral-950 aria-[current=page]:text-neutral-950 dark:text-neutral-400 dark:hover:text-white dark:aria-[current=page]:text-white";
  return (
    <footer class="mx-auto flex w-full max-w-6xl flex-wrap items-center justify-between gap-x-6 px-5 py-5 text-sm sm:px-8">
      <a href={props.home ? "#top" : homeUrl} class="inline-flex items-center gap-2 font-semibold tracking-tight"><BrandMark class="size-6" /> LeNotch</a>
      <nav aria-label="Footer" class="flex flex-wrap items-center gap-x-4 sm:gap-x-6">
        <a href={`${homeUrl}privacy`} class={linkClass}>Privacy policy</a>
        <a href={`${homeUrl}terms`} class={linkClass}>Terms of use</a>
        <Show when={props.home}><a href="#top" class={linkClass}>Back to top ↑</a></Show>
      </nav>
    </footer>
  );
}
