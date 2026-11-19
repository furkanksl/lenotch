import { onSettled } from "solid-js";

interface Star {
  x: number;
  y: number;
  phase: number;
  speed: number;
}

interface Spark {
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
  color: string;
}

export function HeroPixelBackground() {
  let canvasRef: HTMLCanvasElement | undefined;
  let containerRef: HTMLDivElement | undefined;

  onSettled(() => {
    if (!canvasRef || !containerRef) return;
    const canvas = canvasRef;
    const container = containerRef;
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) return;

    let animId: number | null = null;
    let isVisible = true;
    let nativeW = 480;
    let nativeH = 220;
    let lastFrameTime = 0;

    // Offscreen canvas for pre-rendered dithered sky cache (eliminates 8,400+ fillRect calls/frame)
    let skyCanvas: HTMLCanvasElement | null = null;
    let cachedDark: boolean | null = null;

    const isDark = () => document.documentElement.classList.contains("dark");
    const prefersReducedMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;

    // 4x4 Bayer Dither Matrix for retro sky gradient
    const bayer4x4 = [
      [0, 8, 2, 10],
      [12, 4, 14, 6],
      [3, 11, 1, 9],
      [15, 7, 13, 5],
    ];

    // Pre-render the static dithered sky once onto an offscreen canvas
    const buildSkyCache = (dark: boolean) => {
      if (typeof document === "undefined") return;
      if (!skyCanvas) {
        skyCanvas = document.createElement("canvas");
      }
      skyCanvas.width = nativeW;
      skyCanvas.height = nativeH;
      const sCtx = skyCanvas.getContext("2d");
      if (!sCtx) return;

      const cSkyTop = dark ? "#06050b" : "#f5f3fa";
      const cSkyHorizon = dark ? "#1e102e" : "#fae6dc";
      const horizonY = Math.floor(nativeH * 0.46);

      sCtx.fillStyle = cSkyTop;
      sCtx.fillRect(0, 0, nativeW, nativeH);

      const startY = Math.floor(horizonY * 0.3);
      const spanY = horizonY * 0.7;

      for (let y = startY; y < horizonY; y += 2) {
        const tVal = (y - startY) / spanY;
        const threshold = tVal * 16;
        const rowBayer = bayer4x4[(y / 2) % 4];

        for (let x = 0; x < nativeW; x += 2) {
          if (rowBayer[(x / 2) % 4] < threshold) {
            sCtx.fillStyle = cSkyHorizon;
            sCtx.fillRect(x, y, 2, 2);
          }
        }
      }

      cachedDark = dark;
    };

    // Precomputed projection lookup tables for 3D perspective grid
    const GRID_COLS = 50;
    const GRID_ROWS = 24;
    const fov = 170;
    const camY = 46;

    const scaleTable = new Float32Array(GRID_ROWS);
    const rowAlphaTable = new Float32Array(GRID_ROWS);
    const ptSizeTable = new Uint8Array(GRID_ROWS);

    for (let r = 0; r < GRID_ROWS; r++) {
      const z = r;
      scaleTable[r] = fov / (fov + z * 8 + 24);
      rowAlphaTable[r] = 1 - (z / GRID_ROWS) * 0.45;
      ptSizeTable[r] = z < 6 ? 3 : z < 15 ? 2 : 1;
    }

    const gridXTable = new Float32Array(GRID_COLS);
    for (let c = 0; c < GRID_COLS; c++) {
      gridXTable[c] = (c - GRID_COLS / 2) * 11;
    }

    // Responsive native grid: scales native pixel resolution to preserve 1:1 square pixel blocks
    const updateDimensions = () => {
      const rect = container.getBoundingClientRect();
      const w = Math.max(rect.width, 320);
      const h = Math.max(rect.height, 200);
      const aspect = w / h;

      nativeH = 220;
      nativeW = Math.max(320, Math.floor(nativeH * aspect));

      canvas.width = nativeW;
      canvas.height = nativeH;
      ctx.imageSmoothingEnabled = false;

      buildSkyCache(isDark());
    };

    updateDimensions();

    // 40 retro pixel stars in the upper sky
    const stars: Star[] = Array.from({ length: 42 }, () => ({
      x: Math.random(),
      y: Math.random() * 0.44,
      phase: Math.random() * Math.PI * 2,
      speed: 0.0015 + Math.random() * 0.002,
    }));

    // Interactive mouse coordinates mapped to native grid
    let mouseX = -100;
    let mouseY = -100;
    let mouseActive = false;
    let mouseTimeout: number | null = null;

    const sparks: Spark[] = [];

    const onMouseMove = (e: MouseEvent) => {
      const rect = container.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      mouseX = Math.floor(((e.clientX - rect.left) / rect.width) * nativeW);
      mouseY = Math.floor(((e.clientY - rect.top) / rect.height) * nativeH);
      mouseActive = true;

      if (mouseTimeout) clearTimeout(mouseTimeout);
      mouseTimeout = window.setTimeout(() => {
        mouseActive = false;
      }, 1000);

      // Spawn reactive pixel spark at cursor
      if (sparks.length < 24 && Math.random() < 0.4) {
        sparks.push({
          x: mouseX + (Math.random() - 0.5) * 8,
          y: mouseY + (Math.random() - 0.5) * 8,
          vx: (Math.random() - 0.5) * 0.7,
          vy: -0.4 - Math.random() * 0.5,
          life: 0,
          maxLife: 20 + Math.floor(Math.random() * 12),
          color: Math.random() < 0.5 ? "#fe5302" : "#fdca6e",
        });
      }
    };

    window.addEventListener("mousemove", onMouseMove, { passive: true });

    // Preallocated coordinate flat buffers for batching 1,200+ points by color (cuts state changes by 99%)
    const maxPoints = GRID_COLS * GRID_ROWS;
    const bWhite = new Int16Array(maxPoints * 3);
    const bOrange = new Int16Array(maxPoints * 3);
    const bAmber = new Int16Array(maxPoints * 3);
    const bTrough = new Int16Array(maxPoints * 3);
    const bLines = new Int16Array(maxPoints * 4);

    const targetFrameInterval = 1000 / 60; // 60fps frame pacing to save battery on 120Hz ProMotion displays

    const render = (time: number) => {
      animId = requestAnimationFrame(render);
      if (!isVisible) return;

      // Frame throttle: cap at steady 60fps to prevent wasting GPU cycles on 120Hz displays
      const delta = time - lastFrameTime;
      if (delta < targetFrameInterval - 1) return;
      lastFrameTime = time;

      const dark = isDark();

      // Invalidate and rebuild sky cache when theme toggles
      if (cachedDark !== dark) {
        buildSkyCache(dark);
      }

      ctx.clearRect(0, 0, nativeW, nativeH);

      // 1. Blit pre-rendered dithered sky cache in 1 single draw call (replaces 8,400+ fillRect calls)
      if (skyCanvas) {
        ctx.drawImage(skyCanvas, 0, 0);
      }

      const horizonY = Math.floor(nativeH * 0.46);
      const centerX = Math.floor(nativeW * 0.5);

      // 2. Pixel Stars in the upper sky (only 40 iterations)
      for (let i = 0; i < stars.length; i++) {
        const s = stars[i];
        const pulse = Math.sin(time * s.speed + s.phase) * 0.5 + 0.5;
        if (pulse < 0.25) continue;

        const alpha = dark ? 0.2 + pulse * 0.7 : 0.12 + pulse * 0.4;
        ctx.fillStyle = dark
          ? pulse > 0.8
            ? `rgba(255, 255, 255, ${alpha})`
            : `rgba(253, 202, 110, ${alpha})`
          : `rgba(254, 83, 2, ${alpha})`;

        const sx = Math.floor(s.x * nativeW);
        const sy = Math.floor(s.y * horizonY);

        ctx.fillRect(sx, sy, 1, 1);
        if (pulse > 0.88) {
          ctx.fillRect(sx - 1, sy, 3, 1);
          ctx.fillRect(sx, sy - 1, 1, 3);
        }
      }

      // 3. 3D PERSPECTIVE PIXEL WAVE MATRIX WITH COLOR BATCHING
      const t = prefersReducedMotion ? 0 : time;
      const tWave1 = t * 0.0022;
      const tWave2 = t * 0.0028;
      const tWave3 = t * 0.0035;

      let lenWhite = 0;
      let lenOrange = 0;
      let lenAmber = 0;
      let lenTrough = 0;
      let lenLines = 0;

      for (let r = GRID_ROWS - 1; r >= 0; r--) {
        const scale = scaleTable[r];
        const ptSize = ptSizeTable[r];
        const zTerm = r * 0.28 - tWave2;

        let prevProjX = 0;
        let prevProjY = 0;

        for (let c = 0; c < GRID_COLS; c++) {
          const gx = gridXTable[c];

          // Fast trigonometric wave components
          const wave1 = Math.sin(c * 0.16 + tWave1) * 14;
          const wave2 = Math.cos(zTerm) * 10;
          const wave3 = Math.sin((c + r) * 0.12 + tWave3) * 6;

          let mouseDisplace = 0;
          const projX = Math.floor(centerX + gx * scale);

          // Spatial pruning: avoid Math.hypot on 1,200 points, use fast bounding box + squared distance
          if (mouseActive) {
            const dx = projX - mouseX;
            const dy = horizonY - mouseY;
            const distSq = dx * dx + dy * dy;
            if (distSq < 2025) {
              // 45px radius squared = 2025
              const dist = Math.sqrt(distSq);
              mouseDisplace = (1 - dist / 45) * 18 * Math.sin(t * 0.01 - dist * 0.2);
            }
          }

          const elevation = wave1 + wave2 + wave3 + mouseDisplace;
          const projY = Math.floor(horizonY + (camY - elevation) * scale);

          // Sort coordinates into color buckets to eliminate 2,500+ fillStyle state changes
          if (elevation > 14) {
            bWhite[lenWhite++] = projX;
            bWhite[lenWhite++] = projY;
            bWhite[lenWhite++] = ptSize;
          } else if (elevation > 6) {
            bOrange[lenOrange++] = projX;
            bOrange[lenOrange++] = projY;
            bOrange[lenOrange++] = ptSize;
          } else if (elevation > -4) {
            bAmber[lenAmber++] = projX;
            bAmber[lenAmber++] = projY;
            bAmber[lenAmber++] = ptSize;
          } else {
            bTrough[lenTrough++] = projX;
            bTrough[lenTrough++] = projY;
            bTrough[lenTrough++] = ptSize;
          }

          // Horizontal grid line segment
          if (c > 0 && Math.abs(projX - prevProjX) < 32) {
            bLines[lenLines++] = Math.min(prevProjX, projX);
            bLines[lenLines++] = Math.floor((prevProjY + projY) / 2);
            bLines[lenLines++] = Math.abs(projX - prevProjX);
            bLines[lenLines++] = 1;
          }

          prevProjX = projX;
          prevProjY = projY;
        }
      }

      // Execute batched draw calls (5 draw calls total instead of 2,500+)
      const cOrange = "#fe5302";
      const cAmber = "#fdca6e";
      const cPeach = "#ffb088";
      const cTrough = dark ? "#1a0f2b" : "#ded8eb";

      // 1. Grid connecting lines
      ctx.fillStyle = dark ? "rgba(254, 83, 2, 0.09)" : "rgba(200, 100, 70, 0.08)";
      for (let i = 0; i < lenLines; i += 4) {
        ctx.fillRect(bLines[i], bLines[i + 1], bLines[i + 2], bLines[i + 3]);
      }

      // 2. Wave trough points
      ctx.fillStyle = cTrough;
      for (let i = 0; i < lenTrough; i += 3) {
        ctx.fillRect(bTrough[i], bTrough[i + 1], bTrough[i + 2], bTrough[i + 2]);
      }

      // 3. Wave mid points
      ctx.fillStyle = dark ? cAmber : cPeach;
      for (let i = 0; i < lenAmber; i += 3) {
        ctx.fillRect(bAmber[i], bAmber[i + 1], bAmber[i + 2], bAmber[i + 2]);
      }

      // 4. Wave high points
      ctx.fillStyle = cOrange;
      for (let i = 0; i < lenOrange; i += 3) {
        ctx.fillRect(bOrange[i], bOrange[i + 1], bOrange[i + 2], bOrange[i + 2]);
      }

      // 5. Wave crest peaks
      ctx.fillStyle = dark ? "#ffffff" : cOrange;
      for (let i = 0; i < lenWhite; i += 3) {
        ctx.fillRect(bWhite[i], bWhite[i + 1], bWhite[i + 2], bWhite[i + 2]);
      }

      // 4. Interactive Cursor Sparks (bounded to max 24 items)
      for (let i = sparks.length - 1; i >= 0; i--) {
        const sp = sparks[i];
        sp.x += sp.vx;
        sp.y += sp.vy;
        sp.life += 1;
        if (sp.life >= sp.maxLife) {
          sparks.splice(i, 1);
          continue;
        }

        ctx.fillStyle = sp.color;
        ctx.fillRect(Math.floor(sp.x), Math.floor(sp.y), 2, 2);
      }
    };

    animId = requestAnimationFrame(render);

    const observer = new IntersectionObserver(
      ([entry]) => {
        isVisible = entry.isIntersecting;
      },
      { threshold: 0 },
    );
    observer.observe(container);

    const resizeObserver = new ResizeObserver(() => updateDimensions());
    resizeObserver.observe(container);

    const onVisibilityChange = () => {
      isVisible = !document.hidden;
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      if (animId !== null) cancelAnimationFrame(animId);
      observer.disconnect();
      resizeObserver.disconnect();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("mousemove", onMouseMove);
      if (mouseTimeout) clearTimeout(mouseTimeout);
      skyCanvas = null;
    };
  });

  return (
    <div
      ref={containerRef}
      aria-hidden="true"
      class="pointer-events-none absolute inset-0 -z-10 h-full w-full overflow-hidden [mask-image:radial-gradient(ellipse_at_50%_45%,black_50%,transparent_92%)]"
    >
      <canvas
        ref={canvasRef}
        class="block h-full w-full select-none opacity-60 dark:opacity-85"
        style={{ "image-rendering": "pixelated" }}
      />
    </div>
  );
}
