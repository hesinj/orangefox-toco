#ifndef SHIM_MM_H
#define SHIM_MM_H
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#define INIT
#define malloc_k(a) malloc(a)
#define large_malloc(a) malloc(a)
#define large_free(a) free(a)
#endif
