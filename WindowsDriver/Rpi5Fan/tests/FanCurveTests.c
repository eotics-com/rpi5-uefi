#include <assert.h>
#include "../FanCurve.h"

int main(void)
{
    assert(FanCurvePercent(0, 30) == 30);
    assert(FanCurvePercent(49999, 30) == 30);
    assert(FanCurvePercent(50000, 30) == 40);
    assert(FanCurvePercent(60000, 40) == 50);
    assert(FanCurvePercent(67500, 50) == 70);
    assert(FanCurvePercent(75000, 70) == 100);

    assert(FanCurvePercent(70000, 100) == 100);
    assert(FanCurvePercent(69999, 100) == 70);
    assert(FanCurvePercent(62500, 70) == 70);
    assert(FanCurvePercent(62499, 70) == 50);
    assert(FanCurvePercent(55000, 50) == 50);
    assert(FanCurvePercent(54999, 50) == 40);
    assert(FanCurvePercent(45000, 40) == 40);
    assert(FanCurvePercent(44999, 40) == 30);

    assert(FanCurvePercent(80000, 30) == 100);
    return 0;
}
