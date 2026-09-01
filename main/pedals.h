/*
 * Three analog pedals (throttle / brake / clutch) read from ADC1.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PEDAL_COUNT             3

/* HID axis range reported to the host: 0 = released, 32767 = fully pressed. */
#define PEDAL_AXIS_MAX          32767

/* Samples averaged per channel per loop iteration (cheap noise rejection). */
#define PEDAL_OVERSAMPLE        8

/* Exponential moving average applied on top of the oversampling.
   Smaller = smoother but laggier. 0.25 @ 500 Hz settles in ~10 ms. */
#define PEDAL_EMA_ALPHA         0.25f

/* Auto-ranging: learn each pedal's raw min/max from the movement it sees.
   Set to 0 to use the fixed raw_min/raw_max values in the table in pedals.c. */
#define PEDAL_AUTO_RANGE        1

/* Ignore the first/last few percent of travel, then rescale to full range.
   655 axis counts = 2 % of travel. */
#define PEDAL_DEADZONE_LO       655
#define PEDAL_DEADZONE_HI       655

/* Refuse to scale a range narrower than this many raw counts (divide-by-zero
   guard while auto-ranging is still learning, and sanity guard for a dead pot). */
#define PEDAL_MIN_SPAN          256

typedef struct {
    uint16_t raw;   /* filtered raw ADC counts, 0..4095 */
    uint16_t axis;  /* scaled/deadzoned HID value, 0..PEDAL_AXIS_MAX */
} pedal_state_t;

/* Configure ADC1 and the three pedal channels. */
esp_err_t pedals_init(void);

/* Sample, filter and scale all three pedals. Blocks for the ADC conversions
   (roughly 100 us total with PEDAL_OVERSAMPLE = 8). */
void pedals_read(pedal_state_t out[PEDAL_COUNT]);

/* Human-readable name of pedal `index`, for logging. */
const char *pedals_name(int index);

/* GPIO number wired to pedal `index`, for logging. */
int pedals_gpio(int index);

#ifdef __cplusplus
}
#endif
