#!/usr/bin/env python3
import os
import subprocess
import struct

SCRATCH = "/Users/magrani/.gemini/antigravity/brain/c1037417-4dec-4fe3-a6e1-c510452c977e/scratch"
os.makedirs(SCRATCH, exist_ok=True)

WRAPPER_C = r"""
typedef unsigned char u8;
typedef unsigned long u64;
typedef long s64;

static inline s64 syscall1(s64 n, s64 a1) {
    s64 ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline s64 syscall3(s64 n, s64 a1, s64 a2, s64 a3) {
    s64 ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static int my_strlen(const char *s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

static int starts_with(const char *s, const char *p) {
    while (*p) {
        if (*s++ != *p++) return 0;
    }
    return 1;
}

static int ends_with(const char *s, int slen, const char *suf, int suflen) {
    if (slen < suflen) return 0;
    for (int i = 0; i < suflen; i++) {
        if (s[slen - suflen + i] != suf[i]) return 0;
    }
    return 1;
}

static void my_strcpy(char *dst, const char *src) {
    while ((*dst++ = *src++));
}

__attribute__((used, section(".text.entry")))
void c_main(u64 *sp) {
    int argc = (int)sp[0];
    char **argv = (char **)&sp[1];
    char **envp = &argv[argc + 1];

    int is_arcvm = 0;
    int is_run = 0;
    char new_gpu_arg[128];

    for (int i = 1; i < argc; i++) {
        if (!argv[i]) continue;
        if (starts_with(argv[i], "ARCVM"))
            is_arcvm = 1;
        if (argv[i][0] == 'r' && argv[i][1] == 'u' && argv[i][2] == 'n' && argv[i][3] == 0)
            is_run = 1;
        if (starts_with(argv[i], "vulkan=true,context-types=:virgl:virgl2:venus")) {
            const char *rest = argv[i] + 45;
            const char *prefix = "vulkan=false,context-types=:virgl:virgl2";
            int plen = my_strlen(prefix);
            my_strcpy(new_gpu_arg, prefix);
            my_strcpy(new_gpu_arg + plen, rest);
            argv[i] = new_gpu_arg;
        }
    }

    if (is_arcvm && is_run) {
        for (int fd = 3; fd < 128; fd++) {
            char fdpath[32];
            const char *base = "/proc/self/fd/";
            int p = 0;
            while (base[p]) { fdpath[p] = base[p]; p++; }
            if (fd >= 100) { fdpath[p++] = '0' + (fd / 100); fdpath[p++] = '0' + ((fd / 10) % 10); fdpath[p++] = '0' + (fd % 10); }
            else if (fd >= 10) { fdpath[p++] = '0' + (fd / 10); fdpath[p++] = '0' + (fd % 10); }
            else { fdpath[p++] = '0' + fd; }
            fdpath[p] = 0;

            char target[256];
            s64 len = syscall3(89 /* __NR_readlink */, (s64)fdpath, (s64)target, 255);
            if (len > 13) {
                target[len] = 0;
                if (ends_with(target, (int)len, ".runtime.prop", 13)) {
                    s64 rfd = syscall3(2 /* __NR_open */, (s64)target, 2 /* O_RDWR */, 0);
                    if (rfd >= 0) {
                        char buf[4096];
                        for (int z = 0; z < 4096; z++) buf[z] = 0;
                        s64 rlen = syscall3(0 /* __NR_read */, rfd, (s64)buf, 3584);
                        if (rlen >= 512 && (rlen % 512) == 0) {
                            s64 nul = 0;
                            while (nul < rlen && buf[nul] != 0) nul++;
                            const char *inj = "debug.hwui.renderer=skiagl\n";
                            int ilen = my_strlen(inj);
                            s64 wlen = rlen;
                            if (nul + ilen >= wlen) wlen += 512;
                            if (wlen <= 4096) {
                                for (int k = 0; k < ilen; k++)
                                    buf[nul + k] = inj[k];
                                syscall3(8 /* __NR_lseek */, rfd, 0, 0);
                                syscall3(1 /* __NR_write */, rfd, (s64)buf, wlen);
                            }
                        }
                        syscall1(3 /* __NR_close */, rfd);
                    }
                    break;
                }
            }
        }
    }

    const char *real_bin = "/usr/bin/crosvm.bin";
    syscall3(59 /* __NR_execve */, (s64)real_bin, (s64)argv, (s64)envp);
    syscall1(60 /* __NR_exit */, 127);
}
"""

START_S = r"""
.section .text.entry, "ax", @progbits
.globl _start
_start:
    movq %rsp, %rdi
    andq $-16, %rsp
    callq c_main
    ud2
"""

open(f"{SCRATCH}/wrapper.c", "w").write(WRAPPER_C)
subprocess.run([
    "clang", "--target=x86_64-unknown-linux-gnu", "-march=x86-64",
    "-O2", "-mno-sse", "-mno-red-zone", "-fpie",
    "-fno-stack-protector", "-fno-asynchronous-unwind-tables",
    "-ffreestanding", "-S", f"{SCRATCH}/wrapper.c", "-o", f"{SCRATCH}/wrapper.s"
], check=True)

open(f"{SCRATCH}/wrapper_full.S", "w").write(START_S + "\n" + open(f"{SCRATCH}/wrapper.s").read())
subprocess.run([
    "clang", "--target=x86_64-unknown-linux-gnu", "-march=x86-64",
    "-c", f"{SCRATCH}/wrapper_full.S", "-o", f"{SCRATCH}/wrapper_full.o"
], check=True)

# Parse wrapper_full.o and emit minimal static ELF64 ET_EXEC at 0x400000!
obj = open(f"{SCRATCH}/wrapper_full.o", "rb").read()
e_shoff = struct.unpack_from("<Q", obj, 0x28)[0]
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", obj, 0x3a)
def shdr(i): return struct.unpack_from("<IIQQQQIIQQ", obj, e_shoff + i * e_shentsize)
shstr = shdr(e_shstrndx)[4]
secs = {}
for i in range(e_shnum):
    s = shdr(i)
    name = obj[shstr + s[0] : obj.find(b"\x00", shstr + s[0])].decode()
    secs[name] = (i, s)

t_idx, t_sh = secs[".text.entry"]
code = bytearray(obj[t_sh[4] : t_sh[4] + t_sh[5]])
ro_idx, ro_sh = secs.get(".rodata.str1.1", (-1, (0,0,0,0,0,0)))
rodata = bytes(obj[ro_sh[4] : ro_sh[4] + ro_sh[5]]) if ro_idx != -1 else b""

# Layout at 0x400000: [ELF64 Ehdr (64B) + 1 Phdr (56B) = 120B, padded to 0x80][code][rodata]
LOAD_VMA = 0x400000
CODE_OFF = 0x80
CODE_VMA = LOAD_VMA + CODE_OFF
RO_OFF   = CODE_OFF + ((len(code) + 15) & ~15)
RO_VMA   = LOAD_VMA + RO_OFF

_, sym_sh = secs[".symtab"]
_, str_sh = secs[".strtab"]
syms = []
for off in range(sym_sh[4], sym_sh[4] + sym_sh[5], 24):
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", obj, off)
    sname = obj[str_sh[4] + st_name : obj.find(b"\x00", str_sh[4] + st_name)].decode()
    syms.append((sname, st_shndx, st_value))

if ".rela.text.entry" in secs:
    _, rela_sh = secs[".rela.text.entry"]
    for off in range(rela_sh[4], rela_sh[4] + rela_sh[5], 24):
        r_offset, r_info, r_addend = struct.unpack_from("<QQq", obj, off)
        r_sym, r_type = r_info >> 32, r_info & 0xffffffff
        sname, shndx, svalue = syms[r_sym]
        target_vma = (CODE_VMA if shndx == t_idx else RO_VMA) + svalue
        if r_type in (2, 4): # R_X86_64_PC32 / PLT32
            val = (target_vma + r_addend) - (CODE_VMA + r_offset)
            struct.pack_into("<i", code, r_offset, val)
        elif r_type in (10, 11): # R_X86_64_32 / 32S
            val = target_vma + r_addend
            struct.pack_into("<I", code, r_offset, val)
        else:
            raise RuntimeError(f"Unsupported reloc {r_type}")

total_sz = RO_OFF + len(rodata)
out = bytearray(total_sz)
# Elf64_Ehdr
out[0:16] = b"\x7fELF\x02\x01\x01\x00" + b"\x00"*8
struct.pack_into("<HHIQQQIHHHHHH", out, 16,
    2, 0x3e, 1, CODE_VMA, 64, 0, 0, 64, 56, 1, 0, 0, 0)
# Elf64_Phdr (PT_LOAD, PF_R | PF_X = 5)
struct.pack_into("<IIQQQQQQ", out, 64,
    1, 5, 0, LOAD_VMA, LOAD_VMA, total_sz, total_sz, 0x1000)
out[CODE_OFF : CODE_OFF + len(code)] = code
out[RO_OFF : RO_OFF + len(rodata)] = rodata

out_bin = "/Users/magrani/Downloads/cros_temp/crosvm_wrapper"
open(out_bin, "wb").write(out)
os.chmod(out_bin, 0o755)
print(f"Built static {out_bin}: {len(out)} bytes!")
