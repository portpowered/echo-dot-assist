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

    assert(wy_speaker_volume("{\"type\":\"hassmic-set-volume\"}\n{\"volume\":30}") == 30);
    assert(wy_speaker_volume("{\"type\":\"hassmic-set-volume\",\"data\":{\"volume\":40}}") == 40);  /* inline data */
    assert(wy_failsafe_seconds("{\"type\":\"run-satellite\",\"data\":{\"hassmic_failsafe_seconds\":3}}") == 3);
    assert(wy_speaker_volume("{\"volume\":0}") == 0);
    assert(wy_speaker_volume("{\"volume\":100}") == 100);
    assert(wy_speaker_volume("{}") == -1);
    assert(wy_speaker_volume("{") == -1);
    assert(wy_speaker_volume("{\"type\":\"hassmic-set-volume\"}") == -1);
    const char *volumes[] = {"101", "-1", "1.5", "30.0", "1e1", "\"30\"", "true", "null", "9999999999999999999999"};
    for (unsigned i = 0; i < sizeof volumes / sizeof *volumes; i++) {
        char buf[128]; snprintf(buf, sizeof buf, "{\"volume\":%s}", volumes[i]);
        assert(wy_speaker_volume(buf) == -1);
    }
    puts("ok   volume parser: whole numbers 0..100 only");

    assert(wy_output_mute("{\"type\":\"hassmic-set-output-mute\"}\n{\"mute\":true}") == 1);
    assert(wy_output_mute("{\"mute\":false}") == 0);
    assert(wy_output_mute("{\"type\":\"hassmic-set-output-mute\",\"data\":{\"mute\":true}}") == 1);
    assert(wy_output_mute("{\"type\":\"hassmic-set-output-mute\"}") == -1);     /* the type's "-mute" is no key */
    const char *mutes[] = {"1", "0", "\"true\"", "null", "{}"};
    for (unsigned i = 0; i < sizeof mutes / sizeof *mutes; i++) {
        char buf[128]; snprintf(buf, sizeof buf, "{\"mute\":%s}", mutes[i]);
        assert(wy_output_mute(buf) == -1);
    }
    assert(wy_output_mute("{}") == -1);
    puts("ok   output mute parser: true and false only");
}
