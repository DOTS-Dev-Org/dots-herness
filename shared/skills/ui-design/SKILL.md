---
id: ui-design
name: UI design
description: Build modern, non-generic interfaces with derived fluid tokens, container-query layout, a declared intent manifest for every interactive element, and a runnable audit that proves the UI renders and works across viewports.
---

# UI design

Use when creating or reshaping any user interface: web, iOS, desktop.

Do not invent aesthetics from a blank page. Pick from the constrained menu
below, derive every value from tokens, declare what each control does, then
prove it with the audit. Creativity comes from the DNA choice; correctness
comes from measurement. Never mix the two.

Files next to this one (read them with your file tools, using this skill's
directory path):

- `tokens.css` — the derived fluid token system. Copy it in, do not retype it.
- `audit.mjs` — static check (`node audit.mjs --static <dir>`) and a browser
  snippet for live viewport and dead-control checks.

## 1. Pick a design DNA

Choose exactly one and state the choice before writing code. Every later
decision follows from it. Never blend two.

| DNA | Type pairing | Density | Radius bias | Accent | Depth |
|---|---|---|---|---|---|
| `swiss-minimal` | Inter / Inter tight | airy | `--r-sm` | single ink accent | borders only |
| `soft-brutalist` | Space Grotesk / IBM Plex Mono | compact | `--r-md` | high-chroma single | hard 1px offset border |
| `editorial-serif` | Newsreader / Inter | airy | `--r-sm` | muted warm | none, rules and space |
| `dark-technical` | Geist / Geist Mono | compact | `--r-sm` | one cool signal color | elevation by surface tint |
| `warm-product` | General Sans / Inter | comfortable | `--r-lg` | warm single | one soft shadow tier |

If the user has an existing product, read its current UI first and match its
DNA instead of choosing a new one.

## 2. Derive, never hardcode

Every spacing, size, radius, and font size resolves to a token from
`tokens.css`. A raw `px` value in component code is a defect, with three
exceptions: hairline borders (`1px`), `--tap-min`, and image intrinsic sizes.

**Nested radius law.** An outer container's radius is its inner element's
radius plus the padding between them:

```css
.card { padding: var(--space-3); border-radius: calc(var(--r-md) + var(--space-3)); }
.card > .button { border-radius: var(--r-md); }
```

This is what produces visual hierarchy. Uniform radius everywhere is the
single clearest tell of a generated interface.

**Radius by role**, not by taste: `--r-sm` inputs and chips, `--r-md` buttons
and cards, `--r-lg` sheets and modals, `--r-full` avatars and pills.

## 3. Layout responds to the container, not the screen

Screen width is the wrong signal. A card is narrow in a sidebar and narrow on
a phone; it should behave the same in both.

- Component layout decisions: `@container`. Always.
- `@media`: only global page chrome (nav position, page gutters) and
  capability queries (`pointer`, `prefers-reduced-motion`,
  `prefers-color-scheme`).

```css
.card { container-type: inline-size; }
@container (min-width: 28rem) {
  .card__body { display: grid; grid-template-columns: auto 1fr; gap: var(--space-3); }
}
```

Touch sizing is an input-capability question, never a width question. Any
control must be at least `var(--tap-min)` on both axes when
`(pointer: coarse)`.

## 4. Intent manifest — write it before the markup

Every interactive element gets an entry. No entry, no element. Keep the
manifest next to the component as `<Component>.intent.yaml`.

```yaml
- id: save-draft              # matches data-intent="save-draft" in markup
  label: "Save draft"
  role: button
  action: saveDraft           # a real exported symbol, or route:/path
  states: [idle, loading, error]
  disabled_when: "!isDirty"
  feedback: "toast on success, inline field error on failure"
  keyboard: "Mod+S"
```

Rules:

- `action` must resolve to a symbol or route that exists in the codebase. An
  empty handler, `href="#"`, or a `TODO` is a failure, not a placeholder.
- Every element rendered with `data-intent` must appear in the manifest, and
  every manifest entry must render. The audit checks both directions; the
  second direction is what catches a decorative control nobody wired up.
- A view that can be empty, slow, or fail must have all three of empty,
  loading, and error designed. A view with only its happy path is unfinished.

## 5. Prove it

Never hand over a UI you have not seen rendered. Order matters:

1. `node audit.mjs --static <source-dir>` — hardcoded values, dead handlers,
   manifest and markup drift. Fix everything before rendering.
2. Render and screenshot at each surface:
   - web: 360, 768, 1440 wide
   - iOS: the simulator, both orientations
3. Paste the browser snippet from `audit.mjs` into the live page at each
   width. It reports overflow, clipping, tap targets, contrast, and controls
   that do nothing when activated.
4. Fix, re-render, and look again. One correction round minimum.

Report the audit output. Do not describe a screenshot you did not take.

## 6. Reject before shipping

Any of these means the work is not done:

- Uniform radius across nesting levels, or a radius not from the scale
- Default system font stack when a DNA pairing was chosen
- More than one shadow tier, or shadow used to separate what a border should
- A purple-to-blue gradient, `#6366f1`, or emoji standing in for icons
- No single focal point: everything on screen at the same visual weight
- A media query making a component layout decision
- An interactive element missing from the manifest, or vice versa
- Missing empty, loading, or error state
- Focus never visible when navigating by keyboard
- Contrast below WCAG AA for text, or below 3:1 for control boundaries
