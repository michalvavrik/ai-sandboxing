#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>

__attribute__((constructor))
static void lock_proc(void) {
    prctl(PR_SET_DUMPABLE, 0);
}

static const char PREFIX[] = "BOBSHELL_API_KEY=";
static const size_t PREFIX_LEN = sizeof(PREFIX) - 1;

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
        if (strncmp(envp[i], PREFIX, PREFIX_LEN) != 0)
            filtered[j++] = (char *)envp[i];
    }
    filtered[j] = NULL;

    int ret = real(path, argv, filtered);
    free(filtered);
    return ret;
}
