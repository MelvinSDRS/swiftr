/**
 * The picture a link to swiftr.dev shows in a chat or a feed (1200 × 630),
 * made at build time from the app's own screenshot and icon.
 *
 * The headline is drawn with the fonts of the machine that builds the site:
 * Helvetica Neue on a Mac, the system's sans-serif elsewhere.
 */
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { APIRoute } from 'astro';
import sharp from 'sharp';

const WIDTH = 1200;
const HEIGHT = 630;

// The build runs from site/; the app's pictures are one folder up.
const fromRepo = (path: string) => resolve(process.cwd(), '..', path);

/** Columns of light at both sides, as in the page's hero. */
function columns(): string {
  const bars: string[] = [];
  const heights = [300, 380, 330, 420, 360, 440];
  heights.forEach((height, i) => {
    const offset = i * 34;
    for (const x of [offset, WIDTH - 30 - offset]) {
      bars.push(`<rect x="${x}" y="${HEIGHT - height}" width="30" height="${height}" fill="url(#ember)" />`);
    }
  });
  return bars.join('');
}

export const GET: APIRoute = async () => {
  const [shot, icon] = await Promise.all([
    sharp(await readFile(fromRepo('docs/images/hero-dark.png')))
      .resize({ width: 800 })
      .toBuffer(),
    sharp(await readFile(fromRepo('Swiftr/AppIconLooks.xcassets/AppIconLight.imageset/AppIconLight.png')))
      .resize({ width: 84 })
      .toBuffer(),
  ]);

  const ground = Buffer.from(`
    <svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">
      <defs>
        <linearGradient id="ember" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#F88A36" stop-opacity="0" />
          <stop offset="0.55" stop-color="#F88A36" stop-opacity="0.75" />
          <stop offset="1" stop-color="#FD2020" stop-opacity="0.9" />
        </linearGradient>
      </defs>
      <rect width="100%" height="100%" fill="#000" />
      ${columns()}
      <text x="600" y="150" text-anchor="middle" fill="#F4F1E9" font-size="56" font-weight="300"
        letter-spacing="-1.8" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
        Swift client for herdr-core,
      </text>
      <text x="600" y="218" text-anchor="middle" fill="#F4F1E9" font-size="56" font-weight="300"
        letter-spacing="-1.8" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
        with chat mode for your Agents.
      </text>
    </svg>`);

  const shotHeight = (await sharp(shot).metadata()).height ?? 0;
  const top = 290;
  const picture = await sharp(ground)
    .composite([
      { input: icon, left: 40, top: 28 },
      {
        // The window runs off the picture's foot.
        input: await sharp(shot)
          .extract({ left: 0, top: 0, width: 800, height: Math.min(shotHeight, HEIGHT - top) })
          .toBuffer(),
        left: (WIDTH - 800) / 2,
        top,
      },
    ])
    .png()
    .toBuffer();

  return new Response(new Uint8Array(picture), {
    headers: { 'Content-Type': 'image/png' },
  });
};
