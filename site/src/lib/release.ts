/**
 * The newest release, read from the app's own notes in `release-notes/<version>.txt`,
 * the files `scripts/release.sh` publishes. The page never needs a version typed by hand.
 */

export interface ReleaseSection {
  title: string;
  items: string[];
}

export interface Release {
  version: string;
  sections: ReleaseSection[];
}

const files = import.meta.glob<string>('../../../release-notes/*.txt', {
  query: '?raw',
  import: 'default',
  eager: true,
});

function parts(version: string): number[] {
  return version.split('.').map((part) => Number.parseInt(part, 10) || 0);
}

function newerFirst(a: string, b: string): number {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const diff = (y[i] ?? 0) - (x[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function parse(version: string, text: string): Release {
  const sections: ReleaseSection[] = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('•')) {
      sections.at(-1)?.items.push(line.slice(1).trim());
    } else {
      sections.push({ title: line, items: [] });
    }
  }
  return { version, sections };
}

export function latestRelease(): Release {
  const found = Object.entries(files)
    .map(([path, text]) => ({ version: path.split('/').at(-1)!.replace(/\.txt$/, ''), text }))
    .sort((a, b) => newerFirst(a.version, b.version));
  const newest = found[0];
  if (!newest) throw new Error('No release notes found in release-notes/.');
  return parse(newest.version, newest.text);
}
