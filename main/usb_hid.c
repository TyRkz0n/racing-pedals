#include "usb_hid.h"

#include <stdio.h>

#include "class/hid/hid_device.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "tinyusb.h"

static const char *TAG = "usb_hid";

#define HID_REPORT_ID_PEDALS   1
#define HID_EP_IN_ADDR         0x81
#define HID_EP_SIZE            16   /* report is 7 bytes + 1 report ID */
#define HID_POLL_INTERVAL_MS   1    /* 1000 Hz on a full-speed bus */

/*
 * HID report descriptor: a joystick with three absolute 16-bit axes and eight
 * buttons.
 *
 * 16-bit axes (rather than TinyUSB's stock TUD_HID_REPORT_DESC_GAMEPAD, whose
 * axes are 8-bit) keep the full 12-bit ADC resolution intact - 8-bit axes would
 * quantise pedal travel into 256 steps, which is visible as stepping on a brake.
 *
 * The buttons are always reported as zero. They exist because some titles and
 * calibration UIs ignore a HID device that declares no buttons at all; wiring
 * real switches later is then just a matter of filling in report.buttons.
 */
static const uint8_t hid_report_descriptor[] = {
    0x05, 0x01,                    /* Usage Page (Generic Desktop)        */
    0x09, 0x04,                    /* Usage (Joystick)                    */
    0xA1, 0x01,                    /* Collection (Application)            */
    0x85, HID_REPORT_ID_PEDALS,    /*   Report ID (1)                     */
    0x09, 0x01,                    /*   Usage (Pointer)                   */
    0xA1, 0x00,                    /*   Collection (Physical)             */
    0x09, 0x30,                    /*     Usage (X)  - throttle           */
    0x09, 0x31,                    /*     Usage (Y)  - brake              */
    0x09, 0x32,                    /*     Usage (Z)  - clutch             */
    0x15, 0x00,                    /*     Logical Minimum (0)             */
    0x27, 0xFF, 0x7F, 0x00, 0x00,  /*     Logical Maximum (32767)         */
    0x75, 0x10,                    /*     Report Size (16)                */
    0x95, 0x03,                    /*     Report Count (3)                */
    0x81, 0x02,                    /*     Input (Data,Var,Abs)            */
    0xC0,                          /*   End Collection                    */
    0x05, 0x09,                    /*   Usage Page (Button)               */
    0x19, 0x01,                    /*   Usage Minimum (Button 1)          */
    0x29, 0x08,                    /*   Usage Maximum (Button 8)          */
    0x15, 0x00,                    /*   Logical Minimum (0)               */
    0x25, 0x01,                    /*   Logical Maximum (1)               */
    0x75, 0x01,                    /*   Report Size (1)                   */
    0x95, 0x08,                    /*   Report Count (8)                  */
    0x81, 0x02,                    /*   Input (Data,Var,Abs)              */
    0xC0,                          /* End Collection                      */
};

/* Espressif's vendor ID with the PID their TinyUSB HID examples use. Replace
   both with your own allocation if this ever ships as a product. */
static const tusb_desc_device_t hid_device_descriptor = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,
    .bDeviceClass       = 0x00,
    .bDeviceSubClass    = 0x00,
    .bDeviceProtocol    = 0x00,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor           = 0x303A,
    .idProduct          = 0x4004,
    .bcdDevice          = 0x0100,
    .iManufacturer      = 0x01,
    .iProduct           = 0x02,
    .iSerialNumber      = 0x03,
    .bNumConfigurations = 0x01,
};

/* Filled from the factory MAC in usb_hid_init() so two boards on one PC get
   distinct entries in the Windows game-controller list. */
static char s_serial[13] = "000000000000";

static const char *s_string_descriptor[5] = {
    (const char[]){ 0x09, 0x04 },  /* 0: language = English (0x0409) */
    "DIY",                         /* 1: manufacturer */
    "ESP32-S3 Racing Pedals",      /* 2: product */
    s_serial,                      /* 3: serial number */
    "Pedals HID",                  /* 4: HID interface */
};

#define TUSB_DESC_TOTAL_LEN (TUD_CONFIG_DESC_LEN + CFG_TUD_HID * TUD_HID_DESC_LEN)

static const uint8_t hid_configuration_descriptor[] = {
    /* config number, interface count, string index, total length, attributes, power (mA) */
    TUD_CONFIG_DESCRIPTOR(1, 1, 0, TUSB_DESC_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),
    /* interface number, string index, boot protocol, report descriptor len, EP in, size, interval */
    TUD_HID_DESCRIPTOR(0, 4, false, sizeof(hid_report_descriptor), HID_EP_IN_ADDR, HID_EP_SIZE, HID_POLL_INTERVAL_MS),
};

/* ---------------- TinyUSB callbacks (called from the TinyUSB task) --------- */

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance)
{
    (void)instance;  /* single HID instance */
    return hid_report_descriptor;
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t report_type,
                               uint8_t *buffer, uint16_t reqlen)
{
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)buffer;
    (void)reqlen;
    return 0;  /* nothing to serve over the control pipe */
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t report_type,
                           uint8_t const *buffer, uint16_t bufsize)
{
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)buffer;
    (void)bufsize;  /* the host has nothing to say to a set of pedals */
}

/* ---------------------------------- API ----------------------------------- */

esp_err_t usb_hid_init(void)
{
    uint8_t mac[6] = { 0 };
    if (esp_efuse_mac_get_default(mac) == ESP_OK) {
        snprintf(s_serial, sizeof(s_serial), "%02X%02X%02X%02X%02X%02X",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }

    const tinyusb_config_t tusb_cfg = {
        .device_descriptor        = &hid_device_descriptor,
        .string_descriptor        = s_string_descriptor,
        .string_descriptor_count  = sizeof(s_string_descriptor) / sizeof(s_string_descriptor[0]),
        .external_phy             = false,
#if (TUD_OPT_HIGH_SPEED)
        .fs_configuration_descriptor = hid_configuration_descriptor,
        .hs_configuration_descriptor = hid_configuration_descriptor,
        .qualifier_descriptor        = NULL,
#else
        .configuration_descriptor    = hid_configuration_descriptor,
#endif
    };

    ESP_RETURN_ON_ERROR(tinyusb_driver_install(&tusb_cfg), TAG, "tinyusb_driver_install failed");
    ESP_LOGI(TAG, "USB HID gamepad started (serial %s)", s_serial);
    return ESP_OK;
}

bool usb_hid_mounted(void)
{
    return tud_mounted();
}

bool usb_hid_send(const pedal_hid_report_t *report)
{
    if (!tud_mounted() || !tud_hid_ready()) {
        return false;
    }
    return tud_hid_report(HID_REPORT_ID_PEDALS, report, sizeof(*report));
}
