#include <stdio.h>
int main(){asm volatile("amswap.w $zero, $ra, $zero" ::: "memory");puts("AMO_OK");return 0;}
