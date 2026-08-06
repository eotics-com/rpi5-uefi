/**
 * Experimental Raspberry Pi 5 Active Cooler KMDF driver.
 *
 * This driver binds only to the ACPI\\RPI0FAN device published by the
 * companion UEFI patch. Every error path requests the maximum supported fan
 * duty before returning.
 *
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 */

#include "Rpi5Fan.h"
#include "FanCurve.h"

#define FAN_TIMER_MS                    2000
#define FAN_FAILSAFE_PERCENT            100
#define RP1_PWM1_FROM_CLOCKS             0x00084000ll
#define RP1_GPIO2_FROM_CLOCKS            0x000c0000ll
#define RP1_PADS2_FROM_CLOCKS            0x000e0000ll
#define BCM2712_MAILBOX_PHYSICAL         0x000000107c013880ll

#define FAN_GPIO_PIN_IN_BANK            11
#define FAN_GPIO_CTRL                   (FAN_GPIO_PIN_IN_BANK * 8 + 0x004)
#define FAN_GPIO_FUNCSEL_MASK           0x01f
#define FAN_GPIO_OUTOVER_MASK           0x3000
#define FAN_GPIO_OEOVER_MASK            0xc000
#define FAN_PAD_CTRL                    (0x004 + FAN_GPIO_PIN_IN_BANK * 4)
#define FAN_PAD_OUT_DISABLE             (1u << 7)
#define FAN_PAD_INPUT_ENABLE            (1u << 6)
#define FAN_PAD_PULL_MASK               ((1u << 3) | (1u << 2))
#define FAN_PAD_PULL_DOWN               (1u << 2)

#define CLOCK_PWM1_CTRL                 0x084
#define CLOCK_PWM1_DIV_INT              0x088
#define CLOCK_PWM1_DIV_FRAC             0x08c
#define CLOCK_PWM1_SEL                  0x090
#define CLOCK_ENABLE                    (1u << 11)
#define CLOCK_AUXSRC_MASK               0x3e0
#define CLOCK_SRC_MASK                  (1u << 0)
#define CLOCK_AUXSRC_XOSC               (2u << 5)
#define CLOCK_SRC_AUX                   (1u << 0)

#define PWM_GLOBAL_CTRL                 0x000
#define PWM_CHANNEL                     3
#define PWM_CHANNEL_CTRL                (0x014 + PWM_CHANNEL * 0x10)
#define PWM_RANGE                       (0x018 + PWM_CHANNEL * 0x10)
#define PWM_DUTY                        (0x020 + PWM_CHANNEL * 0x10)
#define PWM_CHANNEL_DEFAULT             ((1u << 8) | (1u << 0))
#define PWM_POLARITY_INVERTED           (1u << 3)
#define PWM_CHANNEL_ENABLE              (1u << PWM_CHANNEL)
#define PWM_SET_UPDATE                  (1u << 31)
#define PWM_PERIOD_TICKS                2078
#define PWM_MAX_DUTY_TICKS              2038

#define MBOX_READ                       0x00
#define MBOX_STATUS                     0x18
#define MBOX_WRITE                      0x20
#define MBOX_STATUS_FULL                (1u << 31)
#define MBOX_STATUS_EMPTY               (1u << 30)
#define MBOX_PROPERTY_CHANNEL           8u
#define MBOX_BUS_ALIAS                  0xc0000000u
#define MBOX_GET_TEMPERATURE            0x00030006u
#define MBOX_RESPONSE_SUCCESS           0x80000000u
#define MBOX_TAG_RESPONSE               0x80000000u
#define MBOX_POLL_COUNT                 1000
#define MBOX_POLL_DELAY_US              10

static __forceinline ULONG
FanRead32(_In_ PUCHAR Base, _In_ ULONG Offset)
{
    return READ_REGISTER_ULONG((PULONG)(Base + Offset));
}

static __forceinline VOID
FanWrite32(_In_ PUCHAR Base, _In_ ULONG Offset, _In_ ULONG Value)
{
    WRITE_REGISTER_ULONG((PULONG)(Base + Offset), Value);
}

static VOID
FanUnmapResources(_Inout_ PFAN_DEVICE_CONTEXT Context)
{
    if (Context->Clocks != NULL) {
        MmUnmapIoSpace(Context->Clocks, Context->ClocksLength);
        Context->Clocks = NULL;
    }
    if (Context->Pwm != NULL) {
        MmUnmapIoSpace(Context->Pwm, Context->PwmLength);
        Context->Pwm = NULL;
    }
    if (Context->Gpio != NULL) {
        MmUnmapIoSpace(Context->Gpio, Context->GpioLength);
        Context->Gpio = NULL;
    }
    if (Context->Pads != NULL) {
        MmUnmapIoSpace(Context->Pads, Context->PadsLength);
        Context->Pads = NULL;
    }
    if (Context->Mailbox != NULL) {
        MmUnmapIoSpace(Context->Mailbox, Context->MailboxLength);
        Context->Mailbox = NULL;
    }
}

static NTSTATUS
FanSetPercent(_Inout_ PFAN_DEVICE_CONTEXT Context, _In_ UCHAR Percent)
{
    ULONG value;

    if (!Context->HardwareReady || Percent > 100) {
        return STATUS_DEVICE_NOT_READY;
    }

    value = FanRead32(Context->Clocks, CLOCK_PWM1_CTRL);
    FanWrite32(Context->Clocks, CLOCK_PWM1_CTRL, value & ~CLOCK_ENABLE);
    FanWrite32(Context->Clocks, CLOCK_PWM1_DIV_INT, 1);
    FanWrite32(Context->Clocks, CLOCK_PWM1_DIV_FRAC, 0);
    FanWrite32(Context->Clocks, CLOCK_PWM1_SEL, 1u << 1);
    value = FanRead32(Context->Clocks, CLOCK_PWM1_CTRL);
    value &= ~(CLOCK_AUXSRC_MASK | CLOCK_SRC_MASK);
    value |= CLOCK_AUXSRC_XOSC | CLOCK_SRC_AUX | CLOCK_ENABLE;
    FanWrite32(Context->Clocks, CLOCK_PWM1_CTRL, value);

    value = FanRead32(Context->Pads, FAN_PAD_CTRL);
    value &= ~(FAN_PAD_OUT_DISABLE | FAN_PAD_PULL_MASK);
    value |= FAN_PAD_INPUT_ENABLE | FAN_PAD_PULL_DOWN;
    FanWrite32(Context->Pads, FAN_PAD_CTRL, value);

    value = FanRead32(Context->Gpio, FAN_GPIO_CTRL);
    value &= ~(FAN_GPIO_FUNCSEL_MASK | FAN_GPIO_OUTOVER_MASK |
               FAN_GPIO_OEOVER_MASK);
    FanWrite32(Context->Gpio, FAN_GPIO_CTRL, value);

    FanWrite32(Context->Pwm, PWM_CHANNEL_CTRL,
               PWM_CHANNEL_DEFAULT | PWM_POLARITY_INVERTED);
    FanWrite32(Context->Pwm, PWM_RANGE, PWM_PERIOD_TICKS);
    FanWrite32(Context->Pwm, PWM_DUTY,
               (PWM_MAX_DUTY_TICKS * (ULONG)Percent + 50u) / 100u);
    value = FanRead32(Context->Pwm, PWM_GLOBAL_CTRL) | PWM_CHANNEL_ENABLE;
    FanWrite32(Context->Pwm, PWM_GLOBAL_CTRL, value);
    FanWrite32(Context->Pwm, PWM_GLOBAL_CTRL, value | PWM_SET_UPDATE);
    Context->CurrentPercent = Percent;
    return STATUS_SUCCESS;
}

_Success_(return != FALSE)
static BOOLEAN
FanReadTemperature(_Inout_ PFAN_DEVICE_CONTEXT Context,
                   _Out_ PULONG MilliCelsius)
{
    volatile ULONG *message;
    ULONG request;
    ULONG value;
    ULONG i;

    if (Context->Message == NULL || Context->MessagePhysical.HighPart != 0 ||
        Context->MessagePhysical.LowPart > 0x3fffffffu) {
        return FALSE;
    }

    message = (volatile ULONG *)Context->Message;
    RtlZeroMemory(Context->Message, PAGE_SIZE);
    message[0] = 8u * sizeof(ULONG);
    message[1] = 0;
    message[2] = MBOX_GET_TEMPERATURE;
    message[3] = 2u * sizeof(ULONG);
    message[4] = 0;
    message[5] = 0;
    message[6] = 0;
    message[7] = 0;

    request = (Context->MessagePhysical.LowPart + MBOX_BUS_ALIAS) |
              MBOX_PROPERTY_CHANNEL;
    KeMemoryBarrier();

    while ((FanRead32(Context->Mailbox, MBOX_STATUS) & MBOX_STATUS_EMPTY) == 0) {
        (void)FanRead32(Context->Mailbox, MBOX_READ);
    }

    for (i = 0; i < MBOX_POLL_COUNT; ++i) {
        if ((FanRead32(Context->Mailbox, MBOX_STATUS) & MBOX_STATUS_FULL) == 0) {
            FanWrite32(Context->Mailbox, MBOX_WRITE, request);
            break;
        }
        KeStallExecutionProcessor(MBOX_POLL_DELAY_US);
    }
    if (i == MBOX_POLL_COUNT) {
        return FALSE;
    }

    for (i = 0; i < MBOX_POLL_COUNT; ++i) {
        if ((FanRead32(Context->Mailbox, MBOX_STATUS) & MBOX_STATUS_EMPTY) == 0) {
            value = FanRead32(Context->Mailbox, MBOX_READ);
            if (value == request) {
                KeMemoryBarrier();
                if (message[1] != MBOX_RESPONSE_SUCCESS ||
                    (message[4] & MBOX_TAG_RESPONSE) == 0 ||
                    message[6] > 150000u) {
                    return FALSE;
                }
                *MilliCelsius = message[6];
                return TRUE;
            }
        }
        KeStallExecutionProcessor(MBOX_POLL_DELAY_US);
    }

    return FALSE;
}

VOID
FanEvtTimer(_In_ WDFTIMER Timer)
{
    WDFDEVICE device = (WDFDEVICE)WdfTimerGetParentObject(Timer);
    PFAN_DEVICE_CONTEXT context = FanGetContext(device);
    ULONG temperature;
    UCHAR percent = FAN_FAILSAFE_PERCENT;

    WdfWaitLockAcquire(context->Lock, NULL);
    if (context->HardwareReady &&
        FanReadTemperature(context, &temperature)) {
        percent = FanCurvePercent(temperature, context->CurrentPercent);
    }
    if (context->HardwareReady && percent != context->CurrentPercent) {
        (void)FanSetPercent(context, percent);
    }
    WdfWaitLockRelease(context->Lock);
}

NTSTATUS
FanEvtPrepareHardware(_In_ WDFDEVICE Device,
                      _In_ WDFCMRESLIST ResourcesRaw,
                      _In_ WDFCMRESLIST ResourcesTranslated)
{
    PFAN_DEVICE_CONTEXT context = FanGetContext(Device);
    PHYSICAL_ADDRESS starts[5] = { 0 };
    ULONG lengths[5] = { 0 };
    ULONG memoryCount = 0;
    ULONG count;
    ULONG i;
    PHYSICAL_ADDRESS low = { 0 };
    PHYSICAL_ADDRESS high;
    PHYSICAL_ADDRESS boundary = { 0 };

    UNREFERENCED_PARAMETER(ResourcesRaw);
    count = WdfCmResourceListGetCount(ResourcesTranslated);
    for (i = 0; i < count && memoryCount < RTL_NUMBER_OF(starts); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR descriptor =
            WdfCmResourceListGetDescriptor(ResourcesTranslated, i);
        if (descriptor != NULL && descriptor->Type == CmResourceTypeMemory) {
            starts[memoryCount] = descriptor->u.Memory.Start;
            lengths[memoryCount] = descriptor->u.Memory.Length;
            ++memoryCount;
        }
    }
    if (memoryCount != RTL_NUMBER_OF(starts) ||
        lengths[0] != 0x1000 || lengths[1] != 0x1000 ||
        lengths[2] != 0x1000 || lengths[3] != 0x1000 ||
        lengths[4] != 0x40 ||
        starts[1].QuadPart - starts[0].QuadPart != RP1_PWM1_FROM_CLOCKS ||
        starts[2].QuadPart - starts[0].QuadPart != RP1_GPIO2_FROM_CLOCKS ||
        starts[3].QuadPart - starts[0].QuadPart != RP1_PADS2_FROM_CLOCKS ||
        starts[4].QuadPart != BCM2712_MAILBOX_PHYSICAL) {
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    context->ClocksLength = lengths[0];
    context->PwmLength = lengths[1];
    context->GpioLength = lengths[2];
    context->PadsLength = lengths[3];
    context->MailboxLength = lengths[4];
    context->Clocks = MmMapIoSpaceEx(starts[0], lengths[0], PAGE_READWRITE | PAGE_NOCACHE);
    context->Pwm = MmMapIoSpaceEx(starts[1], lengths[1], PAGE_READWRITE | PAGE_NOCACHE);
    context->Gpio = MmMapIoSpaceEx(starts[2], lengths[2], PAGE_READWRITE | PAGE_NOCACHE);
    context->Pads = MmMapIoSpaceEx(starts[3], lengths[3], PAGE_READWRITE | PAGE_NOCACHE);
    context->Mailbox = MmMapIoSpaceEx(starts[4], lengths[4], PAGE_READWRITE | PAGE_NOCACHE);
    if (context->Clocks == NULL || context->Pwm == NULL ||
        context->Gpio == NULL || context->Pads == NULL ||
        context->Mailbox == NULL) {
        FanUnmapResources(context);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    high.QuadPart = 0x3fffffff;
    context->Message = MmAllocateContiguousMemorySpecifyCache(
        PAGE_SIZE, low, high, boundary, MmNonCached);
    if (context->Message == NULL) {
        FanUnmapResources(context);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    context->MessagePhysical = MmGetPhysicalAddress(context->Message);
    context->CurrentPercent = 0xff;
    context->HardwareReady = TRUE;
    return STATUS_SUCCESS;
}

NTSTATUS
FanEvtReleaseHardware(_In_ WDFDEVICE Device,
                      _In_ WDFCMRESLIST ResourcesTranslated)
{
    PFAN_DEVICE_CONTEXT context = FanGetContext(Device);
    UNREFERENCED_PARAMETER(ResourcesTranslated);

    WdfTimerStop(context->Timer, TRUE);
    WdfWaitLockAcquire(context->Lock, NULL);
    if (context->HardwareReady) {
        (void)FanSetPercent(context, FAN_FAILSAFE_PERCENT);
    }
    context->HardwareReady = FALSE;
    if (context->Message != NULL) {
        MmFreeContiguousMemory(context->Message);
        context->Message = NULL;
    }
    FanUnmapResources(context);
    WdfWaitLockRelease(context->Lock);
    return STATUS_SUCCESS;
}

NTSTATUS
FanEvtD0Entry(_In_ WDFDEVICE Device,
              _In_ WDF_POWER_DEVICE_STATE PreviousState)
{
    PFAN_DEVICE_CONTEXT context = FanGetContext(Device);
    NTSTATUS status;
    UNREFERENCED_PARAMETER(PreviousState);

    WdfWaitLockAcquire(context->Lock, NULL);
    status = FanSetPercent(context, FAN_FAILSAFE_PERCENT);
    WdfWaitLockRelease(context->Lock);
    if (NT_SUCCESS(status)) {
        WdfTimerStart(context->Timer, WDF_REL_TIMEOUT_IN_MS(FAN_TIMER_MS));
    }
    return status;
}

NTSTATUS
FanEvtD0Exit(_In_ WDFDEVICE Device,
             _In_ WDF_POWER_DEVICE_STATE TargetState)
{
    PFAN_DEVICE_CONTEXT context = FanGetContext(Device);
    UNREFERENCED_PARAMETER(TargetState);

    WdfTimerStop(context->Timer, TRUE);
    WdfWaitLockAcquire(context->Lock, NULL);
    if (context->HardwareReady) {
        (void)FanSetPercent(context, FAN_FAILSAFE_PERCENT);
    }
    WdfWaitLockRelease(context->Lock);
    return STATUS_SUCCESS;
}

NTSTATUS
FanEvtDeviceAdd(_In_ WDFDRIVER Driver,
                _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDFDEVICE device;
    PFAN_DEVICE_CONTEXT context;
    WDF_TIMER_CONFIG timerConfig;
    NTSTATUS status;
    UNREFERENCED_PARAMETER(Driver);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = FanEvtPrepareHardware;
    pnp.EvtDeviceReleaseHardware = FanEvtReleaseHardware;
    pnp.EvtDeviceD0Entry = FanEvtD0Entry;
    pnp.EvtDeviceD0Exit = FanEvtD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnp);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FAN_DEVICE_CONTEXT);
    attributes.ExecutionLevel = WdfExecutionLevelPassive;
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) return status;

    context = FanGetContext(device);
    RtlZeroMemory(context, sizeof(*context));
    status = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &context->Lock);
    if (!NT_SUCCESS(status)) return status;

    WDF_TIMER_CONFIG_INIT_PERIODIC(&timerConfig, FanEvtTimer, FAN_TIMER_MS);
    timerConfig.AutomaticSerialization = FALSE;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;
    attributes.ExecutionLevel = WdfExecutionLevelPassive;
    status = WdfTimerCreate(&timerConfig, &attributes, &context->Timer);
    return status;
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject,
            _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, FanEvtDeviceAdd);
    return WdfDriverCreate(DriverObject, RegistryPath,
                           WDF_NO_OBJECT_ATTRIBUTES, &config,
                           WDF_NO_HANDLE);
}
