#include "../../src/hassmic/wyoming.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    assert(wy_failsafe_seconds("{}") == 30);
    assert(wy_failsafe_seconds("{\"type\":\"run-satellite\"}") == 30);
    assert(wy_failsafe_seconds("{") == -1);
    assert(wy_failsafe_seconds("{\"hassmic_failsafe_seconds\":1}") == 1);
    assert(wy_failsafe_seconds("{\"hassmic_failsafe_seconds\":2147483647}") == 2147483647);
    const char *invalid[] = {"true", "false", "null", "1.5", "1.0", "1e1", "0", "-1", "2147483648", "9999999999999999999999", "\"1\""};
    for (unsigned i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        char buf[128]; snprintf(buf, sizeof buf, "{\"hassmic_failsafe_seconds\":%s}", invalid[i]);
        assert(wy_failsafe_seconds(buf) == -1);
    }
    assert(wy_failsafe_seconds("{\"type\":\"run-satellite\"}\n{\"hassmic_failsafe_seconds\":2}") == 2);
    puts("ok   watchdog parser: omitted=30, range 1..INT_MAX, invalid types/ranges rejected");
}
