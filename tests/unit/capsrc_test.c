/* capsrc.c: state/capture's lines, the argv the front end's volume index is sent with, the bounded run of that tool
 * and which sends get a line in the log */
#include "capsrc.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int fails;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) fails++; }

static void joined(struct afe_call *c, char *out, size_t n)
{
    out[0] = 0;
    for (int i = 0; c->argv[i]; i++) { strncat(out, c->argv[i], n - strlen(out) - 2); strcat(out, " "); }
}

static struct capsrc_conf parsed(const char *text, char *notes, size_t cap)
{
    struct capsrc_conf c;
    capsrc_defaults(&c);
    capsrc_parse(text, &c, notes, cap);
    return c;
}

static long long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000LL + t.tv_nsec / 1000000; }

static void runs(const char *how)
{
    char what[120];
    char *ok[] = { "/bin/true", NULL }, *no[] = { "/bin/false", NULL }, *none[] = { "/no/such/tool", NULL }, *slow[] = { "/bin/sleep", "30", NULL };
    snprintf(what, sizeof what, "%s: a tool that ends with 0", how);
    check(capsrc_run(ok, 2000) == 0, what);
    snprintf(what, sizeof what, "%s: a tool that ends with 1", how);
    check(capsrc_run(no, 2000) == 1, what);
    snprintf(what, sizeof what, "%s: no such tool: 127", how);
    check(capsrc_run(none, 2000) == 127, what);
    long long t0 = now_ms();
    int st = capsrc_run(slow, 300);
    long long took = now_ms() - t0;
    snprintf(what, sizeof what, "%s: a tool that hangs: given up after the wait (%lld ms), not after its 30 s", how, took);
    check(st == CAPSRC_RUN_TIMEOUT && took >= 300 && took < 2000, what);
}

int main(void)
{
    struct capsrc_conf c; struct afe_call call; char s[512], notes[1024];

    /* --- state/capture */
    c = parsed("", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_COMMUNICATION && c.asp_index == 80 && !notes[0], "an empty file: voice_communication, index 80, nothing logged");
    check(!strcmp(capsrc_name(c.source), "VOICE_COMMUNICATION"), "its name for the log: VOICE_COMMUNICATION");
    c = parsed("capture_source=voice_communication\n", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_COMMUNICATION && !notes[0], "capture_source=voice_communication");
    c = parsed("capture_source=voice_recognition\n", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_RECOGNITION && c.asp_index == 80 && !notes[0], "capture_source=voice_recognition");
    check(!strcmp(capsrc_name(c.source), "VOICE_RECOGNITION"), "its name for the log: VOICE_RECOGNITION");
    c = parsed("# by hand\r\n\r\n  capture_source = voice_recognition \r\nasp_volume_index=75", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_RECOGNITION && c.asp_index == 75 && !notes[0], "a comment, blank lines, spaces, CRLF, no newline at the end");
    c = parsed("capture_source=voice_recognition\ncapture_source=VOICE_CALL\n", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_COMMUNICATION, "an unknown source: the default, voice_communication");
    check(strstr(notes, "capture_source=VOICE_CALL") && strstr(notes, "using voice_communication"), "... and the log says so");
    c = parsed("capture_source=\n", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_COMMUNICATION && notes[0], "an empty source: the default, logged");
    c = parsed("asp_volume_index=75\n", notes, sizeof notes);
    check(c.asp_index == 75 && c.source == CAPSRC_VOICE_COMMUNICATION && !notes[0], "asp_volume_index=75");
    c = parsed("asp_volume_index=1\n", notes, sizeof notes);
    check(c.asp_index == 1 && !notes[0], "asp_volume_index=1: the lowest");
    c = parsed("asp_volume_index=100\n", notes, sizeof notes);
    check(c.asp_index == 100 && !notes[0], "asp_volume_index=100: the highest");
    static const char *const bad[] = { "0", "101", "-5", "", "loud", "75x", "7.5", "99999999999999999999" };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        char text[80], what[120], said[80];
        snprintf(text, sizeof text, "asp_volume_index=75\nasp_volume_index=%s\n", bad[i]);
        snprintf(said, sizeof said, "asp_volume_index=%s is not a number from 1 to 100, using 80", bad[i]);
        snprintf(what, sizeof what, "asp_volume_index=%s: the default 80, logged", bad[i]);
        c = parsed(text, notes, sizeof notes);
        check(c.asp_index == 80 && strstr(notes, said), what);
    }
    c = parsed("volume=3\nnonsense\ncapture_source=voice_recognition\n", notes, sizeof notes);
    check(c.source == CAPSRC_VOICE_RECOGNITION && strstr(notes, "no setting \"volume\"") && strstr(notes, "\"nonsense\" is not name=value"),
          "an unknown name and a line without '=': logged, the rest taken");
    char tiny[24];
    c = parsed("capture_source=x\nasp_volume_index=y\n", tiny, sizeof tiny);
    check(strlen(tiny) == sizeof tiny - 1 && c.asp_index == 80, "notes longer than their buffer: cut, not past it");

    /* --- state/capture as a file */
    char dir[] = "/tmp/capsrc_test.XXXXXX", path[64];
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("HASSMIC_STATE", dir, 1);
    capsrc_load(&c);
    check(c.source == CAPSRC_VOICE_COMMUNICATION && c.asp_index == 80, "no state/capture: voice_communication, index 80");
    snprintf(path, sizeof path, "%s/capture", dir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fputs("capture_source=voice_recognition\nasp_volume_index=64\n", f);
    fclose(f);
    capsrc_load(&c);
    check(c.source == CAPSRC_VOICE_RECOGNITION && c.asp_index == 64, "state/capture read: voice_recognition, index 64");
    unlink(path); rmdir(dir);

    /* --- the argv: command 5 (current volume), 4 bytes in, 16 back */
    check(capsrc_asp_argv(&call, 80) == 0, "index 80: built");
    joined(&call, s, sizeof s);
    check(!strcmp(s, "/system/bin/service call audiosignalprocessor 3 i32 5 i32 4 i32 80 i32 16 "), s);
    check(call.n == 12 && call.argv[12] == NULL, "12 arguments, NULL after them");
    check(capsrc_asp_argv(&call, 75) == 0, "index 75: built");
    joined(&call, s, sizeof s);
    check(!strcmp(s, "/system/bin/service call audiosignalprocessor 3 i32 5 i32 4 i32 75 i32 16 "), s);

    /* --- the run: no shell, a bounded wait; the same with SIGCHLD ignored, as hassmic has it */
    runs("SIGCHLD as it comes");
    signal(SIGCHLD, SIG_IGN);
    runs("SIGCHLD ignored");
    signal(SIGCHLD, SIG_DFL);

    /* --- which sends are logged */
    int last = CAPSRC_RUN_NEVER;
    check(capsrc_asp_say(&last, 0) == 1, "the first send: logged");
    check(capsrc_asp_say(&last, 0) == 0 && capsrc_asp_say(&last, 0) == 0, "the periodic ones after it, all 0: not logged");
    check(capsrc_asp_say(&last, 10) == 1, "one that fails: logged");
    check(capsrc_asp_say(&last, 10) == 1, "one that fails the same way again: logged");
    check(capsrc_asp_say(&last, CAPSRC_RUN_TIMEOUT) == 1, "one killed after the wait: logged");
    check(capsrc_asp_say(&last, 0) == 1, "back to 0: logged, the status changed");
    check(capsrc_asp_say(&last, 0) == 0, "0 again: not logged");
    last = CAPSRC_RUN_NEVER;
    check(capsrc_asp_say(&last, 10) == 1 && capsrc_asp_say(&last, 0) == 1, "a first send that fails, then 0: both logged");
    capsrc_asp_line(s, sizeof s, 80, 0);
    check(!strcmp(s, "asp: volume index 80 sent (exit 0)"), s);
    capsrc_asp_line(s, sizeof s, 75, 10);
    check(!strcmp(s, "asp: volume index 75 sent (exit 10)"), s);
    capsrc_asp_line(s, sizeof s, 80, CAPSRC_RUN_TIMEOUT);
    check(!strncmp(s, "asp: volume index 80 sent (exit none: killed", 44), s);

    printf("%s\n", fails ? "FAILED" : "all ok");
    return fails != 0;
}
