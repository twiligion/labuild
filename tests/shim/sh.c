#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        return system(argv[2]);
    }
    return 0;
}
