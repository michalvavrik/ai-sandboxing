#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>

__attribute__((constructor))
static void lock_proc(void) {
    prctl(PR_SET_DUMPABLE, 0);
}

/* bob 2.x copies BOBSHELL_API_KEY into BOB_API_KEY at startup */
static const char *const KEY_VARS[] = { "BOBSHELL_API_KEY=", "BOB_API_KEY=" };

static int is_key_var(const char *entry) {
    for (size_t k = 0; k < sizeof(KEY_VARS) / sizeof(KEY_VARS[0]); k++)
        if (strncmp(entry, KEY_VARS[k], strlen(KEY_VARS[k])) == 0)
            return 1;
    return 0;
}

int execve(const char *path, char *const argv[], char *const envp[]) {
    int (*real)(const char *, char *const[], char *const[]) =
        dlsym(RTLD_NEXT, "execve");

    if (!envp)
        return real(path, argv, envp);

    int n = 0;
    while (envp[n]) n++;

    char **filtered = malloc((n + 1) * sizeof(char *));
    if (!filtered)
        return real(path, argv, envp);

    int j = 0;
    for (int i = 0; i < n; i++) {
        if (!is_key_var(envp[i]))
            filtered[j++] = (char *)envp[i];
    }
    filtered[j] = NULL;

    int ret = real(path, argv, filtered);
    free(filtered);
    return ret;
}
