/*
 * USB HID gamepad interface: 3 x 16-bit axes + 8 buttons, over the ESP32-S3's
 * native USB peripheral (the "USB"/OTG connector, GPIO19/GPIO20).
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Wire format of the HID input report (report ID 1 is prepended by TinyUSB). */
typedef struct __attribute__((packed)) {
    uint16_t axis[3];   /* X = throttle, Y = brake, Z = clutch; 0..32767 */
    uint8_t  buttons;   /* 8 buttons, bit 0 = button 1 */
} pedal_hid_report_t;

/* Install the TinyUSB driver and start enumerating as a gamepad. */
esp_err_t usb_hid_init(void);

/* True once the host has configured the device. */
bool usb_hid_mounted(void);

/* Queue one input report. Returns false if the endpoint is busy or not ready. */
bool usb_hid_send(const pedal_hid_report_t *report);

#ifdef __cplusplus
}
#endif
