/**
 * A drawing plays once, when it comes into view, then rests.
 * Without this script, or with reduced motion, every drawing shows its resting state.
 */
export function watchArt(): void {
  if (!matchMedia('(prefers-reduced-motion: no-preference)').matches) return;

  const drawings = document.querySelectorAll<HTMLElement>('[data-art]');
  const watch = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        (entry.target as HTMLElement).dataset.art = 'play';
        watch.unobserve(entry.target);
      }
    },
    { threshold: 0.45 },
  );

  for (const drawing of drawings) {
    drawing.dataset.art = 'wait';
    watch.observe(drawing);
  }
}
