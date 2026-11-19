import { Show } from "solid-js";
import type { ToolId, ToolItem } from "../data/site";
import { ToolIcon } from "./Icons";

const palettes: Record<ToolId, string> = {
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

export function ToolPreview(props: { tool: ToolItem }) {
  return (
    <div class="relative isolate aspect-[1.52] w-full overflow-hidden rounded-[22px] bg-well dark:bg-well-dark">
      <Show when={props.tool.media} keyed fallback={
        <div aria-hidden="true" class={`absolute inset-0 grid place-items-center ${palettes[props.tool.id]}`}>
          <div class="absolute inset-0 bg-[radial-gradient(ellipse_at_50%_16%,white,transparent_74%)] opacity-43 dark:opacity-8" />
          <div class="absolute aspect-square h-[77%] rounded-full border border-current opacity-[0.09]" />
          <ToolIcon id={props.tool.id} class="relative h-[57%] w-auto max-w-[70%]" />
        </div>
      }>
        {(media) => (
          <Show when={media.type === "video"} fallback={
            <img src={media.src} alt={media.alt ?? `${props.tool.name} in LeNotch`} loading="lazy" decoding="async" class="h-full w-full object-contain" />
          }>
            <video src={media.src} poster={media.poster} aria-label={media.alt ?? `${props.tool.name} demo`} muted playsinline controls preload="none" class="h-full w-full bg-black object-contain" />
          </Show>
        )}
      </Show>
    </div>
  );
}
