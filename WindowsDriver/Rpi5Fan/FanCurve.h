/** Pure, platform-independent fan curve helper. */
#pragma once

static __inline unsigned char
FanCurvePercent(unsigned long MilliCelsius, unsigned char CurrentPercent)
{
    unsigned char target;

    if (MilliCelsius >= 75000ul) target = 100;
    else if (MilliCelsius >= 67500ul) target = 70;
    else if (MilliCelsius >= 60000ul) target = 50;
    else if (MilliCelsius >= 50000ul) target = 40;
    else target = 30;

    if (target < CurrentPercent) {
        if (CurrentPercent == 100 && MilliCelsius >= 70000ul) return 100;
        if (CurrentPercent == 70 && MilliCelsius >= 62500ul) return 70;
        if (CurrentPercent == 50 && MilliCelsius >= 55000ul) return 50;
        if (CurrentPercent == 40 && MilliCelsius >= 45000ul) return 40;
    }
    return target;
}
