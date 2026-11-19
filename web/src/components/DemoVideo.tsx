import { siteConfig } from "../data/site";

export function DemoVideo() {
  return (
    <section id="demo" aria-label="Product demo">
      <div class="rounded-[22px] border border-black/8 bg-well p-2 shadow-[inset_0_3px_9px_#1f183d22,inset_0_0_0_1px_#211b3708,0_1px_0_#fffc] sm:rounded-[32px] sm:p-3.5 dark:border-black/50 dark:bg-[#100f13] dark:shadow-[inset_0_4px_12px_#0009,inset_0_0_0_1px_#0004,0_1px_0_#ffffff16]">
        <div class="overflow-hidden rounded-[15px] bg-[#111017] ring-1 ring-black/10 sm:rounded-[21px] dark:ring-white/8">
          <video
            src={siteConfig.demoVideoSrc ?? undefined}
            poster={siteConfig.demoPosterSrc ?? undefined}
            aria-label="LeNotch product demo video"
            controls
            playsinline
            preload="none"
            class="block aspect-video w-full bg-[#111017] object-contain"
          />
        </div>
      </div>
    </section>
  );
}
