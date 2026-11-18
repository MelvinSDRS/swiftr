import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig, fontProviders } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://swiftr.dev',
  integrations: [sitemap()],

  fonts: [
    {
      provider: fontProviders.fontsource(),
      name: 'Host Grotesk',
      cssVariable: '--font-host',
      weights: ['300 800'],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['system-ui', 'sans-serif'],
    },
    {
      provider: fontProviders.fontsource(),
      name: 'Geist Mono',
      cssVariable: '--font-geist-mono',
      weights: ['400 500'],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['ui-monospace', 'monospace'],
    },
  ],

  // A <meta> Content-Security-Policy with a hash for each script and style.
  security: { csp: true },

  vite: {
    plugins: [tailwindcss()],
    // The page reads the app's screenshots, icons and release notes one folder up.
    server: { fs: { allow: ['..'] } },
  },
});
