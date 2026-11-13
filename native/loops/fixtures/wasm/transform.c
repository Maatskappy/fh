#include <stdio.h>
int main(void) {
    int n;
    if (scanf("{\"n\":%d}", &n) != 1 || n < 0 || n > 99) return 2;
    printf("{\"n\":%d}\n", n + 1);
    return 0;
}
