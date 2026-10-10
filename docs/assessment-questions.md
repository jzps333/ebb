# Assessment questions

Edit here without touching code; `web/lib/assessment.ts` mirrors this list.

1. **Age band:** 4 to 5, 6 to 8, 9 to 11, 12 to 14, 15 to 18
2. **What usually comes before a hard moment?** loud places, transitions, crowds, bright lights, being touched, unexpected changes, other
3. **Is your child sensitive to sound?** very, a little, no
4. **Do they like being touched or squeezed when upset?** yes, no, depends
5. **Does vibration on the wrist calm or bother them?** calms, bothers, not sure
6. **Favourite colours** (pick up to 2)
7. **Favourite things:** animals, space, vehicles, nature, shapes, other
8. **Which sounds do they like?** rain, ocean, soft music, brown noise, none
9. **Can they follow a breathing exercise?** yes, with help, no
10. **What already helps?** (free text, kept short)
11. **What signs show they are getting upset?** rocking, hand-flapping, going quiet, shouting, other
12. **Anything we should never do?** (free text)

## Calm profile the AI returns

Each `a | b | c` becomes an enum in the real schema (structured outputs do not support number ranges).

```json
{
  "theme": "ocean | space | forest | shapes | animals",
  "colors": ["blue", "green"],
  "breath_pattern": "slow_4_4 | slow_4_6 | box_4_4_4_4 | none",
  "vibration": "off | gentle | medium",
  "sound": "none | rain | ocean | soft_piano | brown_noise",
  "volume": "off | low | medium",
  "auto_triggers": { "motion": true, "noise": false },
  "noise_sensitivity": "low | medium | high",
  "calm_message": "short sentence shown on screen, under 40 characters",
  "parent_summary": "2-3 plain sentences explaining the choices"
}
```

## Guardrails
- Sound sensitivity "very" → `sound` none and `noise_sensitivity` high.
- Vibration "bothers" → `vibration` off.
- No medical claims or diagnoses in `parent_summary`; it is a support tool alongside the child's care team.
- Use better-evidenced routines (slow breathing, steady quiet sounds); no "healing frequency" claims.
- For OCD-type rituals, avoid "just right" or completion visuals.
