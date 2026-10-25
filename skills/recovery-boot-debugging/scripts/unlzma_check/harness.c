#define STATIC static
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "unlzma_kernel.c"
static unsigned char *outb; static size_t outpos;
static long flush_cb(void *buf, unsigned long n){ memcpy(outb+outpos, buf, n); outpos += n; return n; }
static void err_cb(char *m){ fprintf(stderr, "KERNEL-DECODER ERROR: %s\n", m); }
int main(int argc, char **argv){
  FILE *f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET);
  unsigned char *in=malloc(n); fread(in,1,n,f); fclose(f);
  outb = malloc(400u<<20); long pos=0;
  int r = unlzma(in, n, NULL, flush_cb, NULL, &pos, err_cb);
  printf("unlzma returned %d, produced %zu bytes, consumed %ld of %ld input bytes\n", r, outpos, pos, n);
  if (argc>2){ FILE *g=fopen(argv[2],"rb"); fseek(g,0,SEEK_END); long m=ftell(g); fseek(g,0,SEEK_SET); unsigned char *ref=malloc(m); fread(ref,1,m,g); fclose(g);
     printf("reference %ld bytes: %s\n", m, (m==(long)outpos && !memcmp(ref,outb,m)) ? "IDENTICAL" : "DIFFERENT"); }
  return r;
}
