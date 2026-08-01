#define _GNU_SOURCE
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define KEY_PATH    "/run/bob-secrets/api.key"
#define FILTER_PATH "/usr/local/lib/bob-env-filter.so"
#define BOB_PATH    "/usr/local/bin/bob-real"

int main(int argc, char *argv[]) {
    uid_t caller_uid = getuid();

    FILE *f = fopen(KEY_PATH, "r");
    if (!f) {
        fprintf(stderr, "bob-run: %s: %s\n", KEY_PATH, strerror(errno));
        return 1;
    }
    char key[512];
    if (!fgets(key, sizeof(key), f)) {
        fclose(f);
        fprintf(stderr, "bob-run: key file empty\n");
        return 1;
    }
    fclose(f);

    size_t len = strlen(key);
    while (len > 0 && (key[len - 1] == '\n' || key[len - 1] == '\r'))
        key[--len] = '\0';

    if (len == 0) {
        fprintf(stderr, "bob-run: key file empty\n");
        return 1;
    }

    setenv("BOBSHELL_API_KEY", key, 1);
    setenv("LD_PRELOAD", FILTER_PATH, 1);

    explicit_bzero(key, sizeof(key));

    if (setresuid(caller_uid, caller_uid, caller_uid) != 0) {
        fprintf(stderr, "bob-run: setresuid: %s\n", strerror(errno));
        return 1;
    }

    if (prctl(PR_SET_DUMPABLE, 0) != 0) {
        fprintf(stderr, "bob-run: PR_SET_DUMPABLE: %s\n", strerror(errno));
        return 1;
    }

    char **new_argv = malloc((argc + 3) * sizeof(char *));
    if (!new_argv) {
        fprintf(stderr, "bob-run: malloc failed\n");
        return 1;
    }
    new_argv[0] = BOB_PATH;
    new_argv[1] = "--accept-license";
    new_argv[2] = "--yolo";
    for (int i = 1; i < argc; i++)
        new_argv[i + 2] = argv[i];
    new_argv[argc + 2] = NULL;

    execv(BOB_PATH, new_argv);

    fprintf(stderr, "bob-run: exec: %s\n", strerror(errno));
    return 1;
}
