export const githubRepoUrl = "https://github.com/furkanksl/lenotch";
export const releasesUrl = `${githubRepoUrl}/releases`;

export type LatestDownload =
  | { status: "available"; url: string }
  | { status: "upcoming" | "unavailable" };

export async function getLatestDownload(request: typeof fetch = fetch): Promise<LatestDownload> {
  try {
    const response = await request("https://api.github.com/repos/furkanksl/lenotch/releases/latest", {
      signal: AbortSignal.timeout(8000),
    });
    if (response.status === 404) return { status: "upcoming" };
    if (!response.ok) return { status: "unavailable" };

    const release: {
      draft: boolean;
      prerelease: boolean;
      assets: { state: string; name: string; browser_download_url: string }[];
    } = await response.json();
    if (release.draft || release.prerelease) return { status: "upcoming" };
    if (!Array.isArray(release.assets)) return { status: "unavailable" };
    const dmg = release.assets.find(asset =>
      asset?.state === "uploaded" && /\.dmg$/i.test(asset.name) &&
      typeof asset.browser_download_url === "string" && asset.browser_download_url.startsWith(`${releasesUrl}/download/`)
    );
    return dmg ? { status: "available", url: dmg.browser_download_url } : { status: "upcoming" };
  } catch {
    return { status: "unavailable" };
  }
}
