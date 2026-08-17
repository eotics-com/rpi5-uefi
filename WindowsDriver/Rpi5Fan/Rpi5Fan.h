/**
 * Experimental Raspberry Pi 5 Active Cooler KMDF driver.
 *
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 */

#pragma once

#include <ntddk.h>
#include <wdf.h>

typedef struct _FAN_DEVICE_CONTEXT {
    PUCHAR Clocks;
    ULONG ClocksLength;
    PUCHAR Pwm;
    ULONG PwmLength;
    PUCHAR Gpio;
    ULONG GpioLength;
    PUCHAR Pads;
    ULONG PadsLength;
    PUCHAR Mailbox;
    ULONG MailboxLength;
    PVOID Message;
    PHYSICAL_ADDRESS MessagePhysical;
    WDFTIMER Timer;
    WDFWAITLOCK Lock;
    UCHAR CurrentPercent;
    BOOLEAN HardwareReady;
    BOOLEAN TimerEnabled;
} FAN_DEVICE_CONTEXT, *PFAN_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(FAN_DEVICE_CONTEXT, FanGetContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD FanEvtDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE FanEvtPrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE FanEvtReleaseHardware;
EVT_WDF_DEVICE_D0_ENTRY FanEvtD0Entry;
EVT_WDF_DEVICE_D0_EXIT FanEvtD0Exit;
EVT_WDF_TIMER FanEvtTimer;
