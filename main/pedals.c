#include "pedals.h"

#include <string.h>

#include "esp_adc/adc_oneshot.h"
#include "esp_check.h"
#include "esp_log.h"

static const char *TAG = "pedals";

typedef struct {
    const char   *name;
    adc_channel_t channel;   /* ADC1 channel */
    int           gpio;      /* GPIO the channel is wired to */
    uint16_t      raw_min;   /* raw counts at rest      (used when PEDAL_AUTO_RANGE == 0) */
    uint16_t      raw_max;   /* raw counts fully pressed (ditto) */
    bool          invert;    /* true if the wiper voltage falls as you press */
} pedal_cfg_t;

/*
 * ADC1 on the ESP32-S3 covers GPIO1..GPIO10 as channels 0..9.
 *
 * GPIO4/5/6 are used here because they are plain ADC1 pins: no strapping
 * function (unlike GPIO0/3/45/46), no flash/PSRAM duty (GPIO26..37 on an
 * N16R8), and they leave GPIO19/20 free for the native USB D-/D+ lines.
 *
 * ADC2 is deliberately unused - it is unavailable whenever Wi-Fi is running.
 */
static const pedal_cfg_t s_cfg[PEDAL_COUNT] = {
    { .name = "throttle", .channel = ADC_CHANNEL_3, .gpio = 4, .raw_min = 150, .raw_max = 3950, .invert = false },
    { .name = "brake",    .channel = ADC_CHANNEL_4, .gpio = 5, .raw_min = 150, .raw_max = 3950, .invert = false },
    { .name = "clutch",   .channel = ADC_CHANNEL_5, .gpio = 6, .raw_min = 150, .raw_max = 3950, .invert = false },
};

typedef struct {
    float    filt;      /* EMA state, negative until the first sample */
    uint16_t raw_min;
    uint16_t raw_max;
} pedal_rt_t;

static adc_oneshot_unit_handle_t s_adc;
static pedal_rt_t                s_rt[PEDAL_COUNT];

esp_err_t pedals_init(void)
{
    const adc_oneshot_unit_init_cfg_t unit_cfg = {
        .unit_id  = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    ESP_RETURN_ON_ERROR(adc_oneshot_new_unit(&unit_cfg, &s_adc), TAG, "adc_oneshot_new_unit failed");

    /* 12 dB attenuation gives the widest input window (~0..3.1 V), which is what
       a pot wired across 3V3/GND needs. Absolute voltage accuracy is irrelevant
       here - pedal position is derived from the min/max range, not from volts -
       so no adc_cali scheme is installed. */
    const adc_oneshot_chan_cfg_t chan_cfg = {
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_12,
    };

    for (int i = 0; i < PEDAL_COUNT; i++) {
        ESP_RETURN_ON_ERROR(adc_oneshot_config_channel(s_adc, s_cfg[i].channel, &chan_cfg),
                            TAG, "channel config failed for %s", s_cfg[i].name);

        s_rt[i].filt = -1.0f;
#if PEDAL_AUTO_RANGE
        /* Seed inverted so the very first sweep of the pedal defines the range. */
        s_rt[i].raw_min = 4095;
        s_rt[i].raw_max = 0;
#else
        s_rt[i].raw_min = s_cfg[i].raw_min;
        s_rt[i].raw_max = s_cfg[i].raw_max;
#endif
        ESP_LOGI(TAG, "%-8s -> GPIO%d (ADC1_CH%d)", s_cfg[i].name, s_cfg[i].gpio, (int)s_cfg[i].channel);
    }

#if PEDAL_AUTO_RANGE
    ESP_LOGI(TAG, "auto-ranging enabled: press each pedal through its full travel once after power-up");
#endif
    return ESP_OK;
}

static uint16_t sample_channel(int index)
{
    int acc = 0;
    int n   = 0;

    for (int s = 0; s < PEDAL_OVERSAMPLE; s++) {
        int raw = 0;
        if (adc_oneshot_read(s_adc, s_cfg[index].channel, &raw) == ESP_OK) {
            acc += raw;
            n++;
        }
    }
    return n ? (uint16_t)(acc / n) : 0;
}

void pedals_read(pedal_state_t out[PEDAL_COUNT])
{
    for (int i = 0; i < PEDAL_COUNT; i++) {
        pedal_rt_t *rt  = &s_rt[i];
        uint16_t    raw = sample_channel(i);

        rt->filt = (rt->filt < 0.0f) ? (float)raw
                                     : rt->filt + PEDAL_EMA_ALPHA * ((float)raw - rt->filt);
        uint16_t filtered = (uint16_t)(rt->filt + 0.5f);

#if PEDAL_AUTO_RANGE
        if (filtered < rt->raw_min) {
            rt->raw_min = filtered;
        }
        if (filtered > rt->raw_max) {
            rt->raw_max = filtered;
        }
#endif

        int32_t span = (int32_t)rt->raw_max - (int32_t)rt->raw_min;
        if (span < PEDAL_MIN_SPAN) {
            span = PEDAL_MIN_SPAN;
        }

        int32_t v = ((int32_t)filtered - (int32_t)rt->raw_min) * PEDAL_AXIS_MAX / span;

        /* Clamp into the deadzoned window, then stretch that window back out to
           the full axis range so the pedal still reaches 0 and 32767. */
        const int32_t lo = PEDAL_DEADZONE_LO;
        const int32_t hi = PEDAL_AXIS_MAX - PEDAL_DEADZONE_HI;
        if (v < lo) {
            v = lo;
        } else if (v > hi) {
            v = hi;
        }
        v = (v - lo) * PEDAL_AXIS_MAX / (hi - lo);

        if (s_cfg[i].invert) {
            v = PEDAL_AXIS_MAX - v;
        }

        out[i].raw  = filtered;
        out[i].axis = (uint16_t)v;
    }
}

const char *pedals_name(int index)
{
    return (index >= 0 && index < PEDAL_COUNT) ? s_cfg[index].name : "?";
}

int pedals_gpio(int index)
{
    return (index >= 0 && index < PEDAL_COUNT) ? s_cfg[index].gpio : -1;
}
