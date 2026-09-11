/* duckrepro.c -- freestanding aarch64, no libc.
 * Concurrent shared-address-space (CLONE_VM) storm pinned to the Gold cores,
 * replaying detector_zygote's measured workload: mprotect RW<->RO toggling,
 * madvise(DONTNEED), and the openat(/sys/fs/selinux/status)+mmap(MAP_SHARED)+
 * read+close loop that the wedge always ends on. Multiple tasks share ONE mm,
 * so every mprotect/munmap broadcasts a TLB shootdown across the Gold cores --
 * the cross-core TLB/PTE-permission churn hammer.c (single-threaded) never made.
 *
 * Build: clang --target=aarch64-linux-gnu -static -nostdlib -ffreestanding \
 *              -fno-stack-protector -O2 -o duckrepro duckrepro.c
 * Run:   ./duckrepro [nthreads] [seconds]   (defaults 4 threads pinned 4..7, 60s)
 */
typedef unsigned long u64;

#define __NR_openat 56
#define __NR_close 57
#define __NR_exit 93
#define __NR_write 64
#define __NR_nanosleep 101
#define __NR_clock_gettime 113
#define __NR_sched_setaffinity 122
#define __NR_exit_group 94
#define __NR_clone 220
#define __NR_munmap 215
#define __NR_mmap 222
#define __NR_mprotect 226
#define __NR_madvise 233

#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 1
#define MAP_PRIVATE 2
#define MAP_ANON 0x20
#define MADV_DONTNEED 4
#define O_RDONLY 0
#define O_CLOEXEC 02000000
#define AT_FDCWD -100

static inline long sc(long n,long a,long b,long c,long d,long e,long f){
  register long x8 __asm__("x8")=n, x0 __asm__("x0")=a, x1 __asm__("x1")=b;
  register long x2 __asm__("x2")=c, x3 __asm__("x3")=d, x4 __asm__("x4")=e, x5 __asm__("x5")=f;
  __asm__ volatile("svc #0":"+r"(x0):"r"(x8),"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5):"memory","cc");
  return x0;
}
#define S1(n,a) sc(n,(long)(a),0,0,0,0,0)
#define S2(n,a,b) sc(n,(long)(a),(long)(b),0,0,0,0)
#define S3(n,a,b,c) sc(n,(long)(a),(long)(b),(long)(c),0,0,0)
#define S4(n,a,b,c,d) sc(n,(long)(a),(long)(b),(long)(c),(long)(d),0,0)
#define S6(n,a,b,c,d,e,f) sc(n,(long)(a),(long)(b),(long)(c),(long)(d),(long)(e),(long)(f))

void *memset(void *s,int c,unsigned long n){char*p=s;while(n--)*p++=(char)c;return s;}
void *memcpy(void *d,const void *s,unsigned long n){char*a=d;const char*b=s;while(n--)*a++=*b++;return d;}

static unsigned slen(const char*s){unsigned n=0;while(s[n])n++;return n;}
static void wr(const char*s){S3(__NR_write,2,s,slen(s));}
static void wrn(u64 v){char b[24];int i=22;b[23]=0;b[i--]=10;if(!v)b[i--]=48;while(v){b[i--]=(char)(48+v%10);v/=10;}wr(&b[i+1]);}

static u64 now_ns(void){ u64 ts[2]={0,0}; S2(__NR_clock_gettime,1,ts); return ts[0]*1000000000UL+ts[1]; }
static void sleep1(void){ u64 ts[2]={1,0}; S2(__NR_nanosleep,ts,0); }
static void pin(int cpu){ u64 mask=1UL<<cpu; S3(__NR_sched_setaffinity,0,sizeof(mask),&mask); }

static volatile u64 *slots;   /* per-cpu iteration counters (shared page) */
static char *scratch;
static u64   chunk;           /* bytes per worker (disjoint) */
static int   nthreads;
static volatile u64 g_deadline;  /* ns; workers self-exit past this */

void worker(long idx){
  int cpu = 4 + (int)idx;                 /* Gold cores 4..7 */
  pin(cpu);
  char *base = scratch + (u64)idx*chunk;
  u64 rng = 0x9e3779b97f4a7c15UL ^ (u64)(idx+1)*0x100000001b3UL;
  u64 it = 0;
  static const char sp[] = "/sys/fs/selinux/status";
  u64 npages = chunk/4096;
  for(;;){
    rng ^= rng<<13; rng ^= rng>>7; rng ^= rng<<17;
    u64 off = (rng % npages) * 4096;
    u64 len = ((rng>>20) % 64 + 1) * 4096;   /* 4KB..256KB */
    if(off+len > chunk) len = 4096;
    char *p = base + off;

    S3(__NR_mprotect,p,len,PROT_READ|PROT_WRITE);
    for(u64 o=0;o<len;o+=4096) p[o]=(char)it;      /* dirty each page (AF/dirty rewrite) */
    S3(__NR_mprotect,p,len,PROT_READ);             /* -> RO : break-before-make + TLB shootdown */
    S3(__NR_mprotect,p,len,PROT_READ|PROT_WRITE);  /* -> RW */
    if((it & 7)==0) S3(__NR_madvise,p,len,MADV_DONTNEED);  /* PTE clear + flush */

    long fd = S4(__NR_openat,AT_FDCWD,sp,O_RDONLY|O_CLOEXEC,0);
    if(fd>=0){
      long m = S6(__NR_mmap,0,4096,PROT_READ,MAP_SHARED,fd,0);
      if((u64)m < (u64)-4095){
        volatile char c = *(volatile char*)m; (void)c;
        S2(__NR_munmap,m,4096);
      }
      S1(__NR_close,fd);
    }
    slots[cpu] = ++it;
    if((it & 63)==0 && now_ns() >= g_deadline) S1(__NR_exit,0);
  }
}

/* spawn a CLONE_VM task running worker(idx). parent gets tid; child never returns. */
long spawn(unsigned long flags, void *child_stack_top, long idx);
__asm__(
".text\n.globl spawn\nspawn:\n"
"  mov x19, x2\n"
"  mov x8, #220\n"
"  mov x2, #0\n mov x3, #0\n mov x4, #0\n"
"  svc #0\n"
"  cbz x0, 1f\n"
"  ret\n"
"1:\n"
"  mov x0, x19\n"
"  bl worker\n"
"  mov x8, #94\n mov x0, #0\n svc #0\n"
);

#define CLONE_VM 0x100
#define CLONE_FS 0x200
#define CLONE_FILES 0x400
#define CLONE_SIGHAND 0x800
#define CLONE_SYSVSEM 0x40000

static long atoin(const char*s){ if(!s) return 0; long v=0; while(*s>=48&&*s<=57){v=v*10+(*s-48);s++;} return v; }

int repro_main(long argc, char **argv){
  nthreads = 4; long secs = 60;
  if(argc>1){ long t=atoin(argv[1]); if(t>=1&&t<=8) nthreads=t; }
  if(argc>2){ long s=atoin(argv[2]); if(s>0) secs=s; }

  slots = (volatile u64*)S6(__NR_mmap,0,4096,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANON,-1,0);
  chunk = 8UL*1024*1024;
  u64 total = chunk*nthreads;
  scratch = (char*)S6(__NR_mmap,0,total,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  if((u64)scratch >= (u64)-4095){ wr("scratch mmap failed\n"); return 1; }

  wr("duckrepro: nthreads="); wrn((u64)nthreads);
  wr("duckrepro: concurrent shared-mm storm on Gold cores, secs="); wrn((u64)secs);

  g_deadline = now_ns() + (u64)secs*1000000000UL;
  unsigned long flags = CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_SYSVSEM;
  for(long i=0;i<nthreads;i++){
    void *st = (void*)S6(__NR_mmap,0,131072,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if((u64)st >= (u64)-4095){ wr("stack mmap failed\n"); return 1; }
    void *top = (void*)(((u64)st + 131072) & ~15UL);
    spawn(flags, top, i);
  }

  u64 last[8]; for(int i=0;i<8;i++) last[i]=0;
  u64 hb=0;
  while(now_ns() < g_deadline){
    sleep1();
    wr("hb="); wrn(hb);
    for(int c=4;c<4+nthreads;c++){
      u64 v=slots[c];
      wr("  cpu"); wrn((u64)c); wr("  it="); wrn(v);
      if(v==last[c] && hb>0){ wr("  *** cpu"); wrn((u64)c); wr("  *** STALLED (no progress since last hb)\n"); }
      last[c]=v;
    }
    hb++;
  }
  wr("duckrepro: SURVIVED the window (no wedge)\n");
  S1(__NR_exit_group,0);
  return 0;
}

__asm__(
".text\n.globl _start\n_start:\n"
"  ldr x0, [sp]\n"
"  add x1, sp, #8\n"
"  bl repro_main\n"
"  mov x8, #94\n mov x0, #0\n svc #0\n"
);
