-- IdeaPad Flex 3 11ADA05 clickpad: no physical buttons exposed, so make
-- two-finger tap/click the reliable right-click whenever the hardware
-- cooperates. Explicit mapping: 1=left 2=right 3=middle.
--
-- NOTE: this ELAN controller lifts finger contacts sequentially, so
-- two-finger taps often register as LEFT clicks (libinput decides the tap
-- button from the fingers present at the release instant). The dependable
-- right-click on this hardware is a physical press on the bottom-right
-- corner of the pad (button-area). See docs/clickpad.md.
--
-- Drop this in your Omarchy config as:
--   ~/.config/hypr/input.lua   (user overrides)
--

hl.config({
  input = {
    touchpad = {
      tap_to_click = true,        -- single-finger tap = left click
      tap_button_map = "lrm",     -- 1 finger left, 2 right, 3 middle
      clickfinger_behavior = false, -- keep button-area: corner press = right-click
      natural_scroll = false,     -- Chrome-style scrolling (matches Omarchy default)
      scroll_factor = 0.4,        -- Omarchy default
    },
  },
})