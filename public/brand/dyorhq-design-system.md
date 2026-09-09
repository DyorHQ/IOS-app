# DyorHQ design system

The RWA HQ for social trading

## Direction

DyorHQ combines an editorial wordmark with a precise, restrained trading interface. The serif logo is the identifying element. Prices, forms, and navigation remain functional rather than decorative.

The sole approved identity is the editorial wordmark and interlocking D/Q monogram selected on 2026-09-09. The visual reference is `dyorhq-identity.png`. Older logos, prompts and palette directions are superseded and must not be restored from git history or build output.

## Sources of truth

- `public/design-tokens.css`: interface colors, typefaces, spacing, radii, layers, and motion.
- `app/globals.css`: shared component styling.
- `app/ui/components.tsx`: buttons, segmented choices, percentage chips, switches, ranges, and empty states.
- `app/ui/wordmark.tsx`: one reusable wordmark treatment.
- `/brand`: live component reference, including light/dark controls and input validation.

Do not declare new brand colors or font stacks in feature stylesheets. Extend the token source when a genuinely new semantic role is needed.

## Identity

Use `dyorhq-wordmark.png` for the wordmark and `dyorhq-monogram.png` for the D/Q app icon. Both derive from the approved board. The shared component displays the wordmark without redrawing its letters. Black on light, near-white on dark. Do not recolor individual letters, distort proportions or add a glow. iOS mirrors these assets in its asset catalog; the wordmark uses template rendering for theme adaptation.

Keep at least one lowercase letter-height of surrounding clear space. Use the wordmark at 104px wide or above in the interface. The tagline is separate live Manrope text, at least 12px, and omitted where space is insufficient. Use the D/Q monogram at favicon size. An outlined vector master and optical small-size refinement remain future production assets; the supplied assets are raster artwork. The board's sample watchlist values are illustrative, not live data; its typography specimens are visual approximations. Use the bundled font files and exact CSS tokens for implementation.

## Typography

| Role | Family | Weight | Usage |
| --- | --- | --- | --- |
| Editorial | Bodoni Moda | 400, 500 | Brand and editorial headings, never transaction figures |
| Interface | Manrope | 400, 500, 600 | Body, labels, navigation, buttons, screen headings |
| Numeric | IBM Plex Mono | 400, 500 | Prices, balances, amounts, order books, addresses |

The wordmark is original artwork, not Bodoni Moda text. Bodoni Moda complements its thick-thin serif character. Manrope provides open, readable interface lettering. IBM Plex Mono keeps changing figures aligned.

Fonts are bundled in `public/fonts`, with SIL Open Font License files. No Google Fonts request is needed at runtime. Manrope is preloaded. All faces use `font-display: swap`.

Scale: 12px metadata, 14px labels, 16px body, 18px lead, 24px section titles, 40-72px editorial display. Dense financial rows may use 13-14px figures. Text should not be less than 12px. Use sentence case and normal tracking in controls. Financial data uses tabular figures. Never apply a serif to a numeric amount or switch fonts on a single emphasized word.

## Color

| Token role | Light | Dark |
| --- | --- | --- |
| Canvas `--bg` | #F7F7F5 | #18191B |
| Surface `--card` | #FCFCFA | #242528 |
| Inset `--inner` | #EFEFED | #2D2E32 |
| Primary text `--text` | #18191B | #F7F7F5 |
| Secondary text `--muted` | #606165 | #B0B1B6 |
| Supporting text `--faint` | #6B6C70 | #A3A4AA |
| Control boundary | #85868B | #878990 |
| Positive | #126A4B | #77D8AC |
| Negative | #AD3047 | #F496AA |
| Attention | #775812 | #E4C67D |

Primary actions invert the text/canvas pair. Do not introduce a decorative accent. Positive and negative always have text or sign information, not color alone. Warnings use attention colors. Asset identifiers have their own `--asset-*` namespace, independent of action colors. Token colors are illustrative identifiers, not certified company brand assets.

The whole page shares one theme. System preference is the default; explicit light/dark choices persist locally. No section-level theme flips. The reference palette shows the current theme's roles.

## Shape, spacing and layers

Spacing uses a 4px base with 8, 12, 16, 20, 24, 32, 40, 48, 64px steps. Exceptions are limited to optical type adjustments, icon geometry, and the device mockup.

Radii: 6px badges, 8px compact controls, 12px fields/buttons, 16px cards, 24px sheets. Circular identity avatars and pill-shaped floating navigation are documented exceptions. Phone geometry is illustrative and is not certified hardware modeling.

Layer scale: chrome 20, menu 40, sheet 50, toast 60, preview studio 90. Avoid new arbitrary z-index values. Cards use a border and minimal shadow. Never put blur behind prices, order books, or forms.

## Components and states

### Button

`Button` accepts `variant`, `size`, `busy`, and standard button props. Variants: primary, secondary, ghost, tone-up, tone-down. Sizes: regular, sm, big. Default type is button; forms must explicitly pass submit.

- Default: solid fill, a one-line label, minimum 44px target.
- Hover: subtle brightness change, no outer glow.
- Active: slight scale feedback.
- Focus: visible 2px contrasting outline, 4px offset.
- Disabled: subdued solid surface, actual disabled attribute, no activation.
- Busy: disabled plus `aria-busy`, retain meaningful status text. Announce real progress in the surrounding status region.

### Segmented choices

`Seg` is a labeled group of native toggle buttons, not a tab widget without panels. Active buttons expose `aria-pressed`. Tab reaches buttons; Enter/Space activates. `label` names the group. Use buy/sell variants only for trade-direction decisions.

### Inputs

Visible label above every input. Helper text or error below, connected using `aria-describedby`. Invalid inputs have `aria-invalid`, a contrasting boundary, and a specific error message. Placeholder is not a label. Error example: "Enter 2 to 10 letters, with no spaces or numbers." This reference example does not change the launchpad contract's ticker rules.

### Switch and range

Switch exposes `role=switch`, a descriptive name, and `aria-checked`. Native range inputs have names, min/max/step, and adjacent values. Preserve keyboard support.

### Feedback

Empty states explain what will populate the surface. Loading placeholders reserve dimensions. Success, errors, and action results use specific language. Status messages use polite live regions. Never show a simulated quote as live or imply a UI demonstration submitted a transaction.

## Motion and glass

140ms for tactile feedback, 220ms for selection, 320ms for panels; shared easing `cubic-bezier(.2,.8,.2,1)`. Transitions use opacity and transform where possible. Loading may animate while a task is pending, but decorative loops are removed. Reduced motion and the user's motion toggle remove animation. Reduced transparency replaces glass with an opaque surface.

Liquid glass is a web approximation. It is restricted to floating navigation. The default intensity is 30 percent. Order details and inputs remain opaque.

## Responsive behavior

At narrow widths, documentation uses one column and the app uses the full viewport without a device frame. Preserve safe-area insets and scroll access to all content. Labels do not get hidden to make financial values fit. Charts and order books may use compact labels, but form values stay readable. Avoid fixed widths on form controls; use `min-width: 0` where flex children can shrink.

## Verification and scope

Run `node --test tests/design-system.test.mjs` for token contrast, theme parity, font assets, and retired-style checks. Run `npm run typecheck`, `npm run build`, and `node --test tests/rendered-html.test.mjs` for integration. Browser checks should cover both themes, narrow and desktop layouts, focus, selection, input error/success, and saved theme persistence.

Contrast assertions are not a complete accessibility certification. They validate specified foreground/background pairs; composite surfaces and all interaction flows still require review. Wallet, launchpad, swap, and contract behavior are outside this visual migration and remain unchanged.

## Migration

The prior Signal palette and Geist/Inter font selection are retired. Preference schema v3 retains theme, readability, glass, and motion settings; it no longer accepts arbitrary brand colors, fonts, or corner radii. The old standalone preview URL links to the canonical React preview to avoid a second drifting implementation.

Reference: https://github.com/Leonxlnx/taste-skill
Font sources: https://github.com/google/fonts/tree/main/ofl/bodonimoda, https://github.com/google/fonts/tree/main/ofl/manrope, https://github.com/google/fonts/tree/main/ofl/ibmplexmono
