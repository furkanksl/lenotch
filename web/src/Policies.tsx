import type { JSX } from "@solidjs/web";

function Policy(props: { title: string; summary: string; children: JSX.Element }) {
  return (
    <main class="policy-document">
      <header>
        <time datetime="2026-11-23">Updated November 23, 2026</time>
        <h1>{props.title}</h1>
        <p>{props.summary}</p>
      </header>
      {props.children}
    </main>
  );
}

export function Privacy() {
  return (
    <Policy title="Privacy policy" summary="We don’t collect your personal data or track how you use LeNotch.">
      <section>
        <h2>On your Mac</h2>
        <p>Your notes and to-dos stay on your Mac. Local dictation processes speech there after you download its model. You can turn off permissions in macOS System Settings.</p>
      </section>
      <section>
        <h2>When you connect</h2>
        <p>Chat sends your prompts to OpenAI or Anthropic, depending on your choice. ChatGPT voice and dictation send audio to OpenAI. Account usage checks contact your provider. Lyrics lookups send track details to LRCLIB, and update checks contact GitHub.</p>
      </section>
      <section>
        <h2>On this site</h2>
        <p>We don’t use analytics or tracking cookies. Your browser remembers your light or dark theme on this device.</p>
      </section>
    </Policy>
  );
}

export function Terms() {
  return (
    <Policy title="Terms of use" summary="These terms apply when you use the LeNotch app or website.">
      <section>
        <h2>Your content</h2>
        <p>What you write or record is yours. Only use LeNotch with accounts, files, and conversations you have permission to access.</p>
      </section>
      <section>
        <h2>Connected services</h2>
        <p>If you connect ChatGPT, Claude, or another service, that provider’s terms apply to your use of its service.</p>
      </section>
      <section>
        <h2>No warranty</h2>
        <p>LeNotch is provided as is. We don’t guarantee that every feature will work after macOS or a connected service changes. These terms don’t limit rights you have under applicable law.</p>
      </section>
    </Policy>
  );
}
