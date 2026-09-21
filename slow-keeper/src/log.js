/**
 * Three keepers share one stdout, so every line carries its chain. Without the
 * tag a hosted log stream is three interleaved conversations and the only way
 * to tell which chain rate-limited or which chain claimed is to guess.
 */
export function chainLogger(label) {
  return (...a) => console.log(new Date().toISOString(), `[${label}]`, ...a);
}

export const log = (...a) => console.log(new Date().toISOString(), ...a);
