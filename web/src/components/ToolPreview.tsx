import { Show, createSignal } from "solid-js";
import type { ToolId, ToolItem } from "../data/site";
import { ToolIcon } from "./Icons";

const previewAssets = import.meta.glob<string>("../../assets/tools/*.{mp4,webp}", {
  eager: true,
  import: "default",
  query: "?url&no-inline",
});

const palettes: Record<ToolId, string> = {
  "now-playing": "bg-[#f7ded8] text-[#a34233] dark:bg-[#412824] dark:text-[#ffb9ac]",
  "voice-mode": "bg-[#dce9f6] text-[#335c94] dark:bg-[#222e40] dark:text-[#b6d3fb]",
  timer: "bg-[#fae9cf] text-[#895321] dark:bg-[#413021] dark:text-[#f8ce94]",
  "notch-video": "bg-[#e8e0f8] text-[#6943a5] dark:bg-[#302541] dark:text-[#dcc6fb]",
  "agent-sessions": "bg-[#dcece6] text-[#316759] dark:bg-[#233832] dark:text-[#afe0cf]",
  shelf: "bg-[#eadcf6] text-[#653592] dark:bg-[#302241] dark:text-[#dec1ff]",
  launcher: "bg-[#dce6ff] text-[#2d4eaf] dark:bg-[#222e4a] dark:text-[#b5c8ff]",
  clipboard: "bg-[#f9e3d7] text-[#9b4329] dark:bg-[#412a26] dark:text-[#ffc4aa]",
  dictation: "bg-[#f8dee5] text-[#a32f58] dark:bg-[#402232] dark:text-[#ffb7cd]",
  prompter: "bg-[#e4e0fc] text-[#543faa] dark:bg-[#2c2449] dark:text-[#cbc0ff]",
  chat: "bg-[#f7e7d5] text-[#985024] dark:bg-[#3d2c22] dark:text-[#f6c597]",
  today: "bg-[#dceee1] text-[#2a6a53] dark:bg-[#20372f] dark:text-[#a6e2c6]",
  todo: "bg-[#e7ecd5] text-[#556b2e] dark:bg-[#323821] dark:text-[#d5e4a7]",
  notes: "bg-[#f7ebc8] text-[#805c19] dark:bg-[#3d3320] dark:text-[#f7d88b]",
  shortcuts: "bg-[#e9def8] text-[#743b9a] dark:bg-[#352342] dark:text-[#edc1ff]",
  system: "bg-[#dfe7ec] text-[#3c5b6e] dark:bg-[#253440] dark:text-[#b5d5e5]",
  usage: "bg-[#dceeed] text-[#286768] dark:bg-[#203836] dark:text-[#a5e3df]",
  inbox: "bg-[#f6e1e8] text-[#8f4169] dark:bg-[#3d2737] dark:text-[#f4bfdc]",
};

function ToolClip(props: { src: string; name: string }) {
  const [playback, setPlayback] = createSignal<"idle" | "starting" | "playing" | "ended" | "unavailable">("idle");
  const active = () => playback() === "starting" || playback() === "playing";
  let video!: HTMLVideoElement;

  const stop = () => {
    if (playback() === "unavailable") return;
    setPlayback("idle");
    video.pause();
  };

  const play = () => {
    if (active() || playback() === "unavailable") return;
    if (video.currentTime > 0) video.currentTime = 0;
    setPlayback("starting");
    void video.play().catch((error: DOMException) => {
      // Leaving before the clip loads aborts play(); a blocked hover can still be retried by tapping.
      if (error.name !== "AbortError" && active()) stop();
    });
  };

  return (
    <>
      <video
        ref={video}
        src={props.src}
        aria-hidden="true"
        muted
        playsinline
        preload="none"
        onPlaying={() => {
          if (active()) setPlayback("playing");
        }}
        onEnded={() => {
          if (video.ended && active()) setPlayback("ended");
        }}
        onError={() => setPlayback("unavailable")}
        class={`absolute inset-0 h-full w-full bg-black object-contain ${playback() === "playing" || playback() === "ended" ? "" : "opacity-0"}`}
      />
      <button
        type="button"
        aria-label={`${active() ? "Stop" : "Play"} ${props.name} demo`}
        disabled={playback() === "unavailable"}
        onPointerEnter={(event) => {
          if (event.pointerType === "mouse" && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) play();
        }}
        onPointerLeave={(event) => {
          if (event.pointerType === "mouse") stop();
        }}
        onClick={() => (active() ? stop() : play())}
        onBlur={stop}
        class="absolute inset-0 enabled:cursor-pointer focus-visible:outline-2 focus-visible:-outline-offset-4 focus-visible:outline-neutral-950 dark:focus-visible:outline-white"
      />
    </>
  );
}

export function ToolPreview(props: { tool: ToolItem }) {
  const clip = () => previewAssets[`../../assets/tools/${props.tool.id}.mp4`];
  const poster = () => previewAssets[`../../assets/tools/${props.tool.id}.webp`];

  return (
    <div class="relative isolate aspect-[1.52] w-full overflow-hidden rounded-[22px] bg-well dark:bg-well-dark">
      <Show when={poster()} keyed fallback={
        <div aria-hidden="true" class={`absolute inset-0 grid place-items-center ${palettes[props.tool.id]}`}>
          <div class="absolute inset-0 bg-[radial-gradient(ellipse_at_50%_16%,white,transparent_74%)] opacity-43 dark:opacity-8" />
          <div class="absolute aspect-square h-[77%] rounded-full border border-current opacity-[0.09]" />
          <ToolIcon id={props.tool.id} class="relative h-[57%] w-auto max-w-[70%]" />
        </div>
      }>
        {(src) => (
          <img src={src} alt={clip() ? "" : `${props.tool.name} in LeNotch`} loading="lazy" decoding="async" class="h-full w-full object-contain" />
        )}
      </Show>
      <Show when={clip()} keyed>
        {(src) => <ToolClip src={src} name={props.tool.name} />}
      </Show>
    </div>
  );
}
