// Uniform snapshots at submission start (nvn_mtl.m mtl_sub_snapshot; method from MacNativeGames' usnap): a draw reads a uniform block as it was when
// the submission started, although the CPU rewrites it during the replay (negative control: g_us_on = 0, the draw reads the rewritten bytes); an
// inline update within the submission is seen by the draws after it and not by those before; nearby ranges are merged, each copy keeps its offset
// modulo 256; a range that a GPU write of a submission still running reaches is not copied; a range made unreadable after its pool was registered
// drops that copy and the process goes on (on this thread and on the workers that copy in parts; without the fault guard it ends with SIGBUS).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void crash_install(void);
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w=(want), g=(got); count++; printf("%-84s expected %-10llu → got %-10llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(unsigned w) { static uint64_t s=9500; tex_t t={.serial=s++}; t.d.width=t.d.height=w; t.d.depth=t.d.samples=t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t; }
static void set_rt(chain *c, const tex_t *a) { p_set_rt r={.n=1}; r.color[0]=a; emit(c,OP_SET_RT,&r,sizeof r); p_viewports v={.n=1}; v.v[0][2]=v.v[0][3]=8; emit(c,OP_VIEWPORTS,&v,sizeof v); p_scissor sc={0,0,8,8}; emit(c,OP_SCISSOR,&sc,sizeof sc);
    p_clear_color x={.index=0,.mask=15,.rgba={0,0,0,0}}; emit(c,OP_CLEAR_COLOR,&x,sizeof x); }
static void ds_off(chain *c) { ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP}; p_bind_state x={.kind=5}; memcpy(x.bytes,&d,sizeof d); emit(c,OP_BIND_STATE,&x,sizeof x); }
static void bind_prog(chain *c, prog_t *p) { p_bind_program b={p,3}; emit(c,OP_BIND_PROGRAM,&b,sizeof b); }
static void bind_ubo(chain *c, uint64_t addr, uint64_t size) { p_bind_buf b={NVN_SHADER_STAGE_FRAGMENT,0,addr,size}; emit(c,OP_BIND_UBO,&b,sizeof b); }
static void update_ub(chain *c, uint64_t dst, const void *data, uint64_t n) { uint8_t r[16+64]; memcpy(r,&dst,8); memcpy(r+8,&n,8); memcpy(r+16,data,n); emit(c,OP_UPDATE_UB,r,16+n); }
static void draw_cmd(chain *c) { p_draw d={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; emit(c,OP_DRAW,&d,sizeof d); }
static NvProg *g_tprog;
static void setup_prog(prog_t *pg) {   // full-screen triangle; the fragment shader returns the first float4 of uniform slot 0 (an NVN_RB_CBUF binding)
    NSError *e=nil; id<MTLLibrary> l=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\n"
        "struct U{constant float4 *u[[id(0)]];}; fragment float4 ub(constant U&a[[buffer(0)]]){return a.u[0];}\n" options:nil error:&e];
    if(!l){fprintf(stderr,"%s\n",e.localizedDescription.UTF8String);abort();}
    pg->serial=8500; NvProg *p=[NvProg new]; p->sh[0]=[NvShader new]; p->sh[0]->fn=[l newFunctionWithName:@"v"];
    p->sh[1]=[NvShader new]; p->sh[1]->stage=1; p->sh[1]->fn=[l newFunctionWithName:@"ub"]; p->sh[1]->rf.nb=1; p->sh[1]->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.reg=0,.aid=0};
    p->sh[1]->ae=[p->sh[1]->fn newArgumentEncoderWithBufferIndex:0]; g_tprog=p; serial_put(pg->serial,p);
}
static uint32_t px0(const tex_t *t) {   // pixel (0, 0) of an 8×8 RGBA8 target, read back in this submission, which is committed and waited for
    id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(b);
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    uint64_t f=mtl_sub_commit(); EXPECT("  submission completed",1,mtl_wait(f,5000000000ull)); EXPECT("  no error in the submission's feedback",0,mtl_last_commit_error());
    uint32_t v; memcpy(&v,b.contents,4); return v;
}
static void begin(chain *c) { state_reset(); memset(&R,0,sizeof R); vis_clear(); g_vis_on=g_vis_counting=0; mtl_sub_begin(); uint64_t hh=(uint64_t)c->p; mtl_sub_index(&hh,1); mtl_sub_snapshot(&hh,1); }
static const float RED[4]={1,0,0,1}, GREEN[4]={0,1,0,1}, BLUE[4]={0,0,1,1};
#define C_RED 0xff0000ffu
#define C_GREEN 0xff00ff00u
#define C_BLUE 0xffff0000u
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0); mtl_init(); crash_install();   // production SIGSEGV / SIGBUS handling, so the fault hooks run
    uint8_t *um; if (posix_memalign((void **)&um,getpagesize(),65536)) abort(); memset(um,0,65536); mtl_pool_add(um,65536);
    uint64_t u=(uint64_t)(uintptr_t)um; static prog_t pg; setup_prog(&pg);

    // 1. The CPU rewrites the block after the submission started (as Tears of the Kingdom's worker threads do during the replay)
    for (int on=1; on>=0; on--) {
        g_us_on=on; memcpy(um,RED,16); tex_t a=tex(8); chain c=chain_new();
        set_rt(&c,&a); ds_off(&c); bind_prog(&c,&pg); bind_ubo(&c,u,256); draw_cmd(&c); emit(&c,OP_END,NULL,0);
        begin(&c);
        EXPECT(on?"1. snapshot on: the bound range is copied":"1. snapshot off (negative control): nothing is copied",on,us_find(u,256)!=NULL);
        memcpy(um,GREEN,16);
        uint8_t rd[16]; pend_read(u,rd,16);
        EXPECT(on?"1. replay-time reads (pend_read) see the submit-time bytes":"1. off: replay-time reads see memory",on?0:1,(uint64_t)!memcmp(rd,GREEN,16));
        mtl_exec(c.p);
        EXPECT(on?"1. the draw reads the block as it was at the submit call (red)":"1. off: the draw reads the rewritten block (green)",on?C_RED:C_GREEN,px0(&a));
    }
    g_us_on=1;

    // 2. An inline update within the submission: the draw before it reads the copy, the draw after it what the GPU wrote
    {
        memcpy(um,RED,16); tex_t a=tex(8), b=tex(8); chain c=chain_new(); uint64_t d0=g_us_drops;
        set_rt(&c,&a); ds_off(&c); bind_prog(&c,&pg); bind_ubo(&c,u,256); draw_cmd(&c);
        update_ub(&c,u,BLUE,16);
        set_rt(&c,&b); draw_cmd(&c); emit(&c,OP_END,NULL,0);
        begin(&c); memcpy(um,GREEN,16); mtl_exec(c.p);
        EXPECT("2. draw before the update: the copy (red)",C_RED,px0(&a));   // a and b are read back in two submissions: the first commit carries both draws
        EXPECT(ub_rename_on()?"2. renamed: the update keeps the copy (private copies add it)":"2. DM_NVN_UB_RENAME=0: the update drops the copy",ub_rename_on()?0:1,g_us_drops-d0);
        mtl_sub_begin(); EXPECT("2. draw after the update: the update's bytes (blue)",C_BLUE,px0(&b));
    }

    // 3. Merging (CPU only): two adjacent ranges become one copy, ranges further apart than 256 bytes stay separate, each copy keeps its offset
    //    modulo 256; the update of section 2 has completed, so its range is copied again
    {
        for (int i=0;i<0x3000;i++) um[i]=(uint8_t)(i*7+3);
        chain c=chain_new(); uint64_t s0=g_us_skip_gpu;
        bind_ubo(&c,u,256); bind_ubo(&c,u+256,256); bind_ubo(&c,u+0x1000,512); bind_ubo(&c,u+0x2040,64); bind_ubo(&c,u+0x1100,16); emit(&c,OP_END,NULL,0);
        begin(&c);
        EXPECT("3. three copies",3,g_us_n);
        int ok=g_us_n==3 && g_us[0].lo==u && g_us[0].hi==u+512 && g_us[1].lo==u+0x1000 && g_us[1].hi==u+0x1200 && g_us[2].lo==u+0x2040 && g_us[2].hi==u+0x2080;
        EXPECT("3. copies [u, +512) [u+0x1000, +512) [u+0x2040, +64)",1,ok);
        int al=1, eq=1; for (int i=0;i<g_us_n;i++) { al&=(g_us[i].gpu&255)==(g_us[i].lo&255); eq&=!memcmp(g_us[i].cpu,(const void *)(uintptr_t)g_us[i].lo,g_us[i].hi-g_us[i].lo); }
        EXPECT("3. every copy at the same offset modulo 256 as its range",1,al);
        EXPECT("3. every copy holds the range's bytes",1,eq);
        EXPECT("3. a binding inside a copy finds it",1,us_find(u+0x1100,16)==&g_us[1]);
        EXPECT("3. a binding across two copies finds none",0,us_find(u+0x1180,0x100)!=NULL);
        EXPECT("3. nothing skipped (the earlier GPU write has completed)",0,g_us_skip_gpu-s0);
        us_drop(u+0x11f0,0x20);
        EXPECT("3. a GPU write over the end of one copy drops only that copy",1,!us_find(u+0x1100,16) && us_find(u,512) && us_find(u+0x2040,64));
        mtl_sub_commit(); mtl_finish();
        EXPECT("3. the copies end with their submission",0,g_us_n);
    }

    // 4. A GPU write of a submission still running (its fence not reached) reaches one range: that range is not copied, the others are
    {
        g_us_gwn=0; uint64_t far=g_fence+1000; us_gw w={u+0x1080,u+0x1090,far}; g_us_gw[g_us_gwn++]=w;   // the table holds at least 4096 entries since section 2
        chain c=chain_new(); uint64_t s0=g_us_skip_gpu;
        bind_ubo(&c,u,256); bind_ubo(&c,u+0x1000,256); emit(&c,OP_END,NULL,0);
        begin(&c);
        EXPECT("4. the range the running write reaches is not copied",0,us_find(u+0x1000,256)!=NULL);
        EXPECT("4. the other range is copied",1,us_find(u,256)!=NULL);
        EXPECT("4. counted as skipped",1,g_us_skip_gpu-s0);
        mtl_sub_commit(); mtl_finish(); g_us_gwn=0;
    }

    // 5. A bound range made unreadable after its pool was registered (the game unmapped it): its copy faults, is dropped, the others are kept and
    //    the submission goes on; once on this thread (small total), once on the workers (five 64 KiB ranges, above US_PAR_MIN)
    {
        size_t pg=(size_t)getpagesize(), big=1u<<21; uint8_t *bm; if (posix_memalign((void **)&bm,pg,big)) abort(); memset(bm,0x5a,big); mtl_pool_add(bm,big);
        uint64_t b=(uint64_t)(uintptr_t)bm;
        for (int par=0; par<2; par++) {
            chain c=chain_new(); uint64_t f0=g_us_faults, n0=g_us_par_n;
            if (!par) { bind_ubo(&c,b,256); bind_ubo(&c,b+0x10000,256); }
            else for (int i=0;i<5;i++) bind_ubo(&c,b+(uint64_t)i*0x20000,0x10000);
            emit(&c,OP_END,NULL,0);
            uint64_t bad=par?b+2*0x20000:b+0x10000;
            mprotect((void *)(uintptr_t)(bad&~(uint64_t)(pg-1)),pg,PROT_NONE);
            begin(&c);
            mprotect((void *)(uintptr_t)(bad&~(uint64_t)(pg-1)),pg,PROT_READ|PROT_WRITE);
            EXPECT(par?"5. workers: one fault caught":"5. this thread: one fault caught",1,g_us_faults-f0);
            EXPECT(par?"5. workers: the copies were made in parts":"5. this thread: copied here, not in parts",par?1:0,g_us_par_n-n0);
            EXPECT("5. the unreadable range's copy is dropped (its draws read memory)",0,us_find(bad,256)!=NULL);
            EXPECT("5. the readable range's copy is kept",1,us_find(b,256)!=NULL);
            mtl_sub_commit(); mtl_finish();
        }
    }
    printf("== %d checks, %d failed ==\n",count,fail); return fail!=0;}}
