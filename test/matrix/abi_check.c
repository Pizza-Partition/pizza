#define _GNU_SOURCE
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <stdio.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

/* This helper is built inside the package-source container and relocated with
 * the bundle. Optional argv entries are library SONAMEs to dlopen, so the
 * matrix can test WPE/Mesa/plugin closure as well as loader/libc startup. */
int main(int argc, char **argv) {
    /* The matrix bootstraps via ld.so, then establishes the relative-interpreter CWD. */
    int first_library = 1;
    if (argc >= 3 && strcmp(argv[1], "--bundle-root") == 0) {
        if (chdir(argv[2]) != 0)
            return 7;
        first_library = 3;
    }
    char bundle_root[4096];
    if (!getcwd(bundle_root, sizeof bundle_root))
        return 7;
    const size_t root_length = strlen(bundle_root);
    struct utsname kernel;
    if (uname(&kernel) != 0)
        return 1;
    printf("PIZZA_ABI_KERNEL:%s\nPIZZA_ABI_BUNDLED_GLIBC:%s\n", kernel.release,
           gnu_get_libc_version());
    for (int index = first_library; index < argc; index++) {
        if (!dlopen(argv[index], RTLD_NOW | RTLD_LOCAL)) {
            fprintf(stderr, "PIZZA_ABI_DLOPEN_FAILED:%s:%s\n", argv[index], dlerror());
            return 2;
        }
    }
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps)
        return 3;
    char line[4096];
    unsigned int mapped_files = 0;
    while (fgets(line, sizeof line, maps)) {
        const char *path = strchr(line, '/');
        if (path) {
            mapped_files++;
            if (strncmp(path, bundle_root, root_length) != 0 ||
                (root_length > 1 && path[root_length] != '/')) {
                fprintf(stderr, "PIZZA_ABI_HOST_MAPPING:%s", path);
                fclose(maps);
                return 4;
            }
        }
    }
    if (ferror(maps)) {
        fclose(maps);
        return 5;
    }
    fclose(maps);
    if (!mapped_files)
        return 6;
    printf("PIZZA_ABI_SELF_CONTAINED:mapped_files=%u\n", mapped_files);
    return 0;
}
