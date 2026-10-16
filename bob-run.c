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

    /* bob only accepts run/chat options after the subcommand name; without
     * a subcommand it falls back to chat and takes them up front. run is
     * headless, auto-approves anyway and rejects --auto-approve. */
    int has_sub = argc > 1 && (strcmp(argv[1], "run") == 0 || strcmp(argv[1], "chat") == 0);
    int is_run = has_sub && strcmp(argv[1], "run") == 0;
    /* BOB_PATH + at most 4 injected args + argv[1..argc-1] + NULL */
    char **new_argv = malloc((argc + 5) * sizeof(char *));
    if (!new_argv) {
        fprintf(stderr, "bob-run: malloc failed\n");
        return 1;
    }
    int idx = 0, i = 1;
    new_argv[idx++] = BOB_PATH;
    if (has_sub)
        new_argv[idx++] = argv[i++];
    new_argv[idx++] = "--accept-license";
    new_argv[idx++] = "--max-turns";
    new_argv[idx++] = "1500";
    if (!is_run)
        new_argv[idx++] = "--auto-approve";
    for (; i < argc; i++)
        new_argv[idx++] = argv[i];
    new_argv[idx] = NULL;

    execv(BOB_PATH, new_argv);

    fprintf(stderr, "bob-run: exec: %s\n", strerror(errno));
    return 1;
}
