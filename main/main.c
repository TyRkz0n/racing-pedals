/*
 * ESP32-S3 racing pedals -> USB HID gamepad.
 *
 * Three potentiometers (or hall/load-cell boards with an analog output) are
 * sampled on ADC1 and streamed to the host as a 3-axis joystick over the
 * native USB port.
 */
#include <stdlib.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "pedals.h"
#include "usb_hid.h"

static const char *TAG = "main";

/* 2 ms loop => 500 Hz sampling and, at most, a 500 Hz report rate. */
#define LOOP_PERIOD_MS      2

/* Resend an unchanged report at least this often so the host never sits on a
   stale value after a dropped packet. */
#define IDLE_RESEND_MS      100

/* Suppress reports for changes smaller than this (axis units). ~0.02 % of
   travel: below the ADC's own noise floor, so it only filters dithering. */
#define AXIS_CHANGE_EPS     8

/* Period of the diagnostic line printed on the UART/COM port. */
#define LOG_PERIOD_US       1000000

void app_main(void)
{
    ESP_ERROR_CHECK(pedals_init());
    ESP_ERROR_CHECK(usb_hid_init());

    pedal_state_t      state[PEDAL_COUNT];
    pedal_hid_report_t report    = { 0 };
    pedal_hid_report_t last_sent = { 0 };

    int64_t last_send_us = 0;
    int64_t last_log_us  = 0;

    TickType_t next_wake = xTaskGetTickCount();

    while (1) {
        xTaskDelayUntil(&next_wake, pdMS_TO_TICKS(LOOP_PERIOD_MS));

        pedals_read(state);
        for (int i = 0; i < PEDAL_COUNT; i++) {
            report.axis[i] = state[i].axis;
        }

        const int64_t now = esp_timer_get_time();

        bool changed = false;
        for (int i = 0; i < PEDAL_COUNT; i++) {
            if (abs((int)report.axis[i] - (int)last_sent.axis[i]) >= AXIS_CHANGE_EPS) {
                changed = true;
                break;
            }
        }

        if (changed || (now - last_send_us) >= (IDLE_RESEND_MS * 1000)) {
            if (usb_hid_send(&report)) {
                last_sent    = report;
                last_send_us = now;
            }
        }

        if ((now - last_log_us) >= LOG_PERIOD_US) {
            last_log_us = now;
            ESP_LOGI(TAG, "usb=%-12s %s raw=%4u axis=%5u | %s raw=%4u axis=%5u | %s raw=%4u axis=%5u",
                     usb_hid_mounted() ? "mounted" : "not mounted",
                     pedals_name(0), state[0].raw, state[0].axis,
                     pedals_name(1), state[1].raw, state[1].axis,
                     pedals_name(2), state[2].raw, state[2].axis);
        }
    }
}
