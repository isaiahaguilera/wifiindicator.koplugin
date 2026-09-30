local _ = require("gettext")
return {
    fullname = _("Wi-Fi status & connect"),
    description = _([[Hides Wi-Fi popups and shows a small status icon instead (in the corner and the menu bar), connects to Wi-Fi in the background without freezing the screen, and reconnects after sleep to networks saved in KOReader (Kobo).]]),
    -- Release version: must match the vX.Y.Z tag (checked by .github/workflows/release.yml).
    -- Storefront compares it with the latest GitHub release to offer updates.
    version = "2.0.1",
}
