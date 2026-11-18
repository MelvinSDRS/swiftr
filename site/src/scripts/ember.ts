/**
 * The hero's light: columns of terminal cells lit in the icon's red and orange,
 * drawn by one WebGL2 fragment shader. Each column stands for a pane at work.
 *
 * The canvas sits over a CSS gradient of the same colors, which stays in view
 * when WebGL2 is missing. The loop stops while the hero is off screen or the tab
 * is hidden, and people who ask for reduced motion get one still frame.
 */

const VERTEX = /* glsl */ `#version 300 es
void main() {
  // One triangle that covers the canvas.
  vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}`;

const FRAGMENT = /* glsl */ `#version 300 es
precision highp float;

uniform vec2 uRes;    // canvas size, in pixels
uniform vec2 uCell;   // one terminal cell, in pixels
uniform float uTime;  // seconds
uniform float uIntro; // 0 at load, 1 once the columns have risen
out vec4 outColor;

const float BAR = 7.0; // cells per column, the first one left dark as a gap

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float drift(float x) {
  float i = floor(x);
  float f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(hash(vec2(i, 7.0)), hash(vec2(i + 1.0, 7.0)), f);
}

// How high the column at this bar index stands, from 0 to 1.
float height(float bar, float x) {
  float slow = drift(bar * 0.37 + uTime * 0.05);
  float fast = drift(bar * 1.73 - uTime * 0.09);
  float side = smoothstep(0.0, 0.5, abs(x - 0.5));
  return mix(0.8, 1.0, side) * (0.62 + 0.38 * (slow * 0.65 + fast * 0.35)) * uIntro;
}

void main() {
  vec2 cell = floor(gl_FragCoord.xy / uCell);
  vec2 inCell = fract(gl_FragCoord.xy / uCell);
  vec2 grid = ceil(uRes / uCell);
  vec2 at = (cell + 0.5) / grid; // 0,0 bottom left

  float bar = floor(cell.x / BAR);
  float gap = step(0.5, mod(cell.x, BAR));
  float h = height(bar, at.x);

  // Bright along the column, fading over its top half and at its foot.
  float along = clamp(1.0 - at.y / max(h, 0.001), 0.0, 1.0);
  float lit = smoothstep(0.0, 0.42, along) * smoothstep(0.0, 0.16, at.y);

  // Each cell eases between two levels of its own over about three seconds:
  // a slow shimmer, never a blink.
  float beat = uTime * 0.33 + hash(cell) * 7.0;
  float turn = smoothstep(0.0, 1.0, fract(beat));
  float level = mix(hash(cell + floor(beat) * 0.618), hash(cell + (floor(beat) + 1.0) * 0.618), turn);
  lit *= 0.8 + 0.2 * level;

  // Each cell keeps a thin dark edge, so the grid shows.
  float edge = smoothstep(0.0, 0.14, inCell.x) * smoothstep(1.0, 0.86, inCell.x)
             * smoothstep(0.0, 0.08, inCell.y) * smoothstep(1.0, 0.92, inCell.y);

  vec3 ember = vec3(0.992, 0.125, 0.125);
  vec3 flame = vec3(0.973, 0.541, 0.212);
  vec3 color = mix(ember * 0.6, ember, smoothstep(0.0, 0.35, lit));
  color = mix(color, flame, smoothstep(0.3, 0.9, lit * (0.6 + 0.4 * at.y / max(h, 0.001))));

  // A soft wash between and above the cells, so the columns glow.
  float wash = smoothstep(0.0, 0.6, along) * smoothstep(0.0, 0.2, at.y) * 0.26;

  float alpha = clamp(lit * edge * gap + wash, 0.0, 1.0);
  outColor = vec4(color * alpha, alpha);
}`;

function compile(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;
  console.warn(gl.getShaderInfoLog(shader));
  return null;
}

export function startEmber(canvas: HTMLCanvasElement): void {
  const gl = canvas.getContext('webgl2', {
    alpha: true,
    antialias: false,
    premultipliedAlpha: true,
    powerPreference: 'low-power',
  });
  if (!gl) return;

  const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX);
  const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT);
  const program = gl.createProgram();
  if (!vertex || !fragment || !program) return;
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
  gl.useProgram(program);
  gl.bindVertexArray(gl.createVertexArray());

  const uRes = gl.getUniformLocation(program, 'uRes');
  const uCell = gl.getUniformLocation(program, 'uCell');
  const uTime = gl.getUniformLocation(program, 'uTime');
  const uIntro = gl.getUniformLocation(program, 'uIntro');

  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const FRAME = 1000 / 30; // the columns move slowly: 30 frames a second is enough
  const RISE = 2200; // milliseconds the columns take to rise at load

  let visible = true;
  let frame = 0;
  let last = 0;
  let started = 0;

  function resize(): void {
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.round(canvas.clientWidth * scale);
    const height = Math.round(canvas.clientHeight * scale);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      gl!.viewport(0, 0, width, height);
    }
    // A terminal cell is twice as tall as it is wide; smaller on a phone.
    const cell = (canvas.clientWidth < 700 ? 7 : 10) * scale;
    gl!.uniform2f(uRes, width, height);
    gl!.uniform2f(uCell, cell, cell * 2);
  }

  function draw(now: number): void {
    const rise = still.matches ? 1 : Math.min((now - started) / RISE, 1);
    gl!.uniform1f(uTime, still.matches ? 12 : now / 1000);
    gl!.uniform1f(uIntro, 1 - (1 - rise) ** 4);
    gl!.clearColor(0, 0, 0, 0);
    gl!.clear(gl!.COLOR_BUFFER_BIT);
    gl!.drawArrays(gl!.TRIANGLES, 0, 3);
  }

  function loop(now: number): void {
    frame = 0;
    if (!visible || document.hidden || still.matches) return;
    if (now - last >= FRAME) {
      last = now;
      draw(now);
    }
    frame = requestAnimationFrame(loop);
  }

  function wake(): void {
    resize();
    if (still.matches) {
      draw(performance.now());
    } else if (!frame) {
      frame = requestAnimationFrame(loop);
    }
  }

  new ResizeObserver(wake).observe(canvas);
  new IntersectionObserver(([entry]) => {
    visible = entry?.isIntersecting ?? true;
    if (visible) wake();
  }).observe(canvas);
  document.addEventListener('visibilitychange', wake);
  still.addEventListener('change', wake);

  started = performance.now();
  resize();
  draw(started);
  // Only now does the canvas take over from the CSS gradient under it.
  canvas.dataset.live = '';
  wake();
}
