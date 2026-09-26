# Mascot

The default mascot is `PixelCritter` in `apps/macos/Mascot.swift`: an original 16×14 pixel character with a spark on its head, drawn from code with no image assets.

| Mood | When |
|---|---|
| `working` | typing on a laptop, with a "thinking" pause every ~12 s |
| `thinking` | looking up, thought dots |
| `waiting` | waving, with a "!", when Claude needs you |
| `acknowledging` | happy thumbs-up after you answer |
| `celebrating` | jumping, with sparkles, when a task finishes |
| `idle` | dozing |

To use different art, implement `MascotRenderer` (`view(mood:height:animated:)`) and pass it to `MascotView`. Nothing else in the app references mascot assets.

Official Claude/Anthropic artwork is **not** included. Check Anthropic's brand guidelines before adding any.
