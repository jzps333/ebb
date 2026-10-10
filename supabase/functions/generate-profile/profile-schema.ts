// The calm profile the watch can run. Every value is an option the watch
// actually has, so the AI can never ask for a sound or theme it cannot play.

export const THEMES = ["ocean", "space", "forest", "shapes", "animals"] as const;
export const COLORS = ["blue", "teal", "green", "purple", "pink", "yellow", "orange"] as const;
export const BREATH_PATTERNS = ["slow_4_4", "slow_4_6", "box_4_4_4_4", "none"] as const;
export const VIBRATIONS = ["off", "gentle", "medium"] as const;
export const SOUNDS = ["none", "rain", "ocean", "soft_piano", "brown_noise"] as const;
export const VOLUMES = ["off", "low", "medium"] as const;
export const SENSITIVITIES = ["low", "medium", "high"] as const;

export type CalmProfile = {
  theme: (typeof THEMES)[number];
  colors: (typeof COLORS)[number][];
  breath_pattern: (typeof BREATH_PATTERNS)[number];
  vibration: (typeof VIBRATIONS)[number];
  sound: (typeof SOUNDS)[number];
  volume: (typeof VOLUMES)[number];
  auto_triggers: { motion: boolean; noise: boolean };
  noise_sensitivity: (typeof SENSITIVITIES)[number];
  calm_message: string;
  parent_summary: string;
};

const str = (values: readonly string[]) => ({ type: "STRING", enum: [...values] });

// Gemini responseSchema (OpenAPI subset). No number ranges: enums only.
export const GEMINI_SCHEMA = {
  type: "OBJECT",
  properties: {
    theme: str(THEMES),
    colors: { type: "ARRAY", items: str(COLORS), minItems: 1, maxItems: 2 },
    breath_pattern: str(BREATH_PATTERNS),
    vibration: str(VIBRATIONS),
    sound: str(SOUNDS),
    volume: str(VOLUMES),
    auto_triggers: {
      type: "OBJECT",
      properties: { motion: { type: "BOOLEAN" }, noise: { type: "BOOLEAN" } },
      required: ["motion", "noise"],
    },
    noise_sensitivity: str(SENSITIVITIES),
    calm_message: { type: "STRING", description: "Shown on the watch, under 40 characters, no names" },
    parent_summary: { type: "STRING", description: "2-3 plain sentences for the parent" },
  },
  required: [
    "theme", "colors", "breath_pattern", "vibration", "sound", "volume",
    "auto_triggers", "noise_sensitivity", "calm_message", "parent_summary",
  ],
  propertyOrdering: [
    "theme", "colors", "breath_pattern", "vibration", "sound", "volume",
    "auto_triggers", "noise_sensitivity", "calm_message", "parent_summary",
  ],
};

function pick<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === "string" && (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

function clip(value: unknown, max: number, fallback: string): string {
  const text = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  if (!text) return fallback;
  return text.length <= max ? text : text.slice(0, max - 1).trimEnd() + "…";
}

/**
 * Re-checks whatever the AI returned against the allowed options, then applies
 * the plan's guardrails in code so they hold even if the model ignores them.
 */
export function sanitize(raw: Record<string, unknown>, answers: Record<string, unknown>): CalmProfile {
  const colors = Array.isArray(raw.colors)
    ? [...new Set(raw.colors.filter((c): c is (typeof COLORS)[number] => (COLORS as readonly string[]).includes(c as string)))].slice(0, 2)
    : [];
  const triggers = (raw.auto_triggers ?? {}) as Record<string, unknown>;

  const profile: CalmProfile = {
    theme: pick(raw.theme, THEMES, "ocean"),
    colors: colors.length ? colors : ["blue"],
    breath_pattern: pick(raw.breath_pattern, BREATH_PATTERNS, "slow_4_6"),
    vibration: pick(raw.vibration, VIBRATIONS, "gentle"),
    sound: pick(raw.sound, SOUNDS, "none"),
    volume: pick(raw.volume, VOLUMES, "low"),
    auto_triggers: { motion: triggers.motion === true, noise: triggers.noise === true },
    noise_sensitivity: pick(raw.noise_sensitivity, SENSITIVITIES, "medium"),
    calm_message: clip(raw.calm_message, 40, "You are safe. Breathe with me."),
    parent_summary: clip(raw.parent_summary, 400, "This profile uses slow breathing and gentle cues chosen from your answers."),
  };

  // Guardrails from the plan.
  if (answers.sound_sensitivity === "very") {
    profile.sound = "none";
    profile.noise_sensitivity = "high";
  }
  if (answers.vibration === "bothers") profile.vibration = "off";

  // Keep sound and volume consistent with each other.
  if (profile.sound === "none") profile.volume = "off";
  if (profile.volume === "off") profile.sound = "none";
  return profile;
}

export const SYSTEM_PROMPT = `You design a calming profile for Ebb, a wrist watch that helps a child through
a hard moment with a breathing circle, gentle vibration and a quiet sound.
A parent answered an assessment about their child. Choose the profile that best fits.

Rules:
- Only use the allowed values in the schema.
- If the child is very sensitive to sound, choose sound "none" and noise_sensitivity "high".
- If vibration bothers the child, choose vibration "off".
- If the child cannot follow a breathing exercise, prefer "slow_4_6" (gentler) over "box_4_4_4_4".
- Prefer steady, quiet sounds (rain, brown_noise, ocean) and low volume; "soft_piano" only if they like music.
- Turn on auto_triggers.motion if rocking or hand-flapping are signs they are getting upset; turn on
  auto_triggers.noise if loud places come before hard moments and sound does not bother them.
- Respect anything listed under "never do".
- For a child with OCD-type rituals, avoid themes or wording about finishing or getting things "just right".
- calm_message: under 40 characters, warm, simple, no names, no questions. Example: "You're safe. Breathe with me."
- parent_summary: 2-3 plain sentences explaining the main choices. Say it is a support tool that works
  alongside the child's care team. No medical claims, no diagnoses, no "healing frequency" claims.`;
