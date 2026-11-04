# Status LED palette (`DB_LED_OVERRIDE`)

The KNP01 status LED is a full RGB indicator driven by the on-board companion MCU. Writing
`DB_LED_OVERRIDE` (via `kunadb` or the HA bridge `?do=led&override=N`) forces a fixed state,
overriding Kuna's normal connection-status behavior. `0` releases it back to default. Setting
`DB_LED_MASK` true turns the LED fully off.

Observed values (yours may extend further — the pattern continues with more two-color combos):

| Value | LED | | Value | LED |
|------:|-----|---|------:|-----|
| 0 | default / normal behavior | | 11 | red / blue alternating (police) |
| 1 | red (solid) | | 12 | red / green alternating (Christmas) |
| 2 | red flashing | | 13 | pink-purple / red alternating |
| 3 | **green (solid)** | | 14 | cyan / red alternating |
| 4 | green flashing | | 15 | green / blue alternating |
| 5 | blue (solid) | | 16 | purple / blue alternating |
| 6 | blue flashing | | 17 | blue / cyan alternating |
| 7 | purple / pink (solid) | | 18 | green / purple alternating |
| 8 | purple / pink flashing | | 19 | green / light-blue alternating |
| 9 | teal / cyan (solid) | | 20 | cyan / purple alternating |
| 10 | teal / cyan flashing | | … | more alternating combos |

## Ideas
- **Security state:** `3` green = disarmed, `1` red = armed-away, `2` red-flash = alarm tripped.
- **Motion beacon:** `11` red/blue on motion (see `device/ha-bridge/motion_led.sh`), back to `3`.
- **Seasonal:** `12` red/green in December, `11` red/blue on the 4th of July.
- **Privacy:** `DB_LED_MASK` the LED off overnight, green by day.

> Trade-off: forcing a fixed override means the LED no longer signals the camera's real
> connection state. That's fine once the unit is fully local.

## The palette is model-specific — re-map per board
The table above is the **KNP01 porch light**. Other models number the colors differently, so step
`DB_LED_OVERRIDE` on each board and watch. Example — the Kuna **Toucan** (board *Coconut*):

| Value | LED | | Value | LED |
|------:|-----|---|------:|-----|
| 1 | red | | 7 | purple |
| 2 | red flash | | 8 | purple flash |
| 3 | amber (solid) | | 9 | light blue |
| 4 | amber flash | | 10 | light-blue flash |
| 5 | blue (solid) | | 11 | red/blue alternating |
| 6 | blue flash | | 0 | default (amber-flash = no cloud) |

Note the Coconut has **no pure green** — a good "idle" pick there is `5` (blue), with `11` for motion.
