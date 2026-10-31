#!/usr/bin/env python3
import os
import subprocess
import struct

SCRATCH = "/Users/magrani/.gemini/antigravity/brain/c1037417-4dec-4fe3-a6e1-c510452c977e/scratch"
os.makedirs(SCRATCH, exist_ok=True)

C_CODE = r"""
typedef unsigned char u8;
typedef signed char s8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef int s32;
typedef unsigned long u64;
typedef long s64;

#ifdef HOST_TEST
#include <string.h>
static u64 raw_copy_user(void *dst, const void *src, u32 len) {
    if ((u64)dst == 0 || (u64)src == 0) return len;
    memcpy(dst, src, len);
    return 0;
}
#define USER_MAX 0x7fffffffffffULL
#define SEC_ATTR
#else
extern u64 copy_user_generic(void *dst, const void *src, u32 len);
#define raw_copy_user copy_user_generic
#define USER_MAX 0x7ffffffff000ULL
#define SEC_ATTR __attribute__((used, section(".text.movbe")))
#endif

SEC_ATTR __attribute__((noinline))
static u64 *reg_ptr(u64 *regs, int r) {
    int idx = (r == 4) ? 19 : (int)((0x01236789ed405cbaULL >> (r * 4)) & 0xf);
    return &regs[idx];
}

SEC_ATTR
int emulate_movbe(u64 *regs) {
    if (regs[17] != 0x33)
        return 0;

    u64 ip = regs[16];
    if (ip >= USER_MAX - 16)
        return 0;

    u8 buf[16];
    u32 n = 0x1000 - (u32)(ip & 0xfff);
    if (n > 15) n = 15;
    if (raw_copy_user(buf, (const void *)ip, n) != 0)
        return 0;
    /* If instruction straddles page boundary (n < 15), try fetching rest into buf+n */
    if (n < 15 && raw_copy_user(buf + n, (const void *)(ip + n), 15 - n) == 0)
        n = 15;
    u32 valid = n;

    u32 pos = 0;
    u8 flags = 0; /* bit0=osz16, bit1=asz32 */
    #pragma clang loop unroll(disable) vectorize(disable)
    for (; pos < valid; pos++) {
        u8 b = buf[pos];
        if (b == 0x66) flags |= 1;
        else if (b == 0x67) flags |= 2;
        else if (b == 0x2e || b == 0x3e || b == 0x26 || b == 0x36) {}
        else break;
    }

    u8 rex = 0;
    if (pos < valid && (buf[pos] & 0xf0) == 0x40)
        rex = buf[pos++];

    if (pos + 4 > valid || buf[pos] != 0x0f || buf[pos + 1] != 0x38)
        return 0;
    u8 op = buf[pos + 2];
    if ((op & 0xfe) != 0xf0)
        return 0;
    pos += 3;

    u8 modrm = buf[pos++];
    int mod = modrm >> 6;
    if (mod == 3)
        return 0;

    int reg = ((modrm >> 3) & 7) | ((rex & 4) << 1);
    int rm_low = modrm & 7;
    u64 ea;

    if (mod == 0 && rm_low == 5) {
        if (pos + 4 > valid) return 0;
        s32 d = *(const s32 *)(buf + pos);
        pos += 4;
        ea = ip + pos + (s64)d;
    } else {
        u64 base = 0, index = 0;
        int need_disp = mod;
        if (rm_low == 4) {
            if (pos >= valid) return 0;
            u8 sib = buf[pos++];
            int idx_r = ((sib >> 3) & 7) | ((rex & 2) << 2);
            int base_l = sib & 7;
            if (idx_r != 4)
                index = (*reg_ptr(regs, idx_r)) << (sib >> 6);
            if (mod == 0 && base_l == 5)
                need_disp = 2;
            else
                base = *reg_ptr(regs, base_l | ((rex & 1) << 3));
        } else {
            base = *reg_ptr(regs, rm_low | ((rex & 1) << 3));
        }
        s64 disp = 0;
        if (need_disp == 1) {
            if (pos + 1 > valid) return 0;
            disp = (s8)buf[pos++];
        } else if (need_disp == 2) {
            if (pos + 4 > valid) return 0;
            disp = *(const s32 *)(buf + pos);
            pos += 4;
        }
        ea = base + index + disp;
    }

    if (flags & 2)
        ea = (u32)ea;

    u32 size = (rex & 8) ? 8 : ((flags & 1) ? 2 : 4);
    if (ea > USER_MAX || ea + size > USER_MAX)
        return 0;

    u64 *rp = reg_ptr(regs, reg);
    u64 tmp = 0;
    if (op == 0xf0) {
        if (raw_copy_user(&tmp, (const void *)ea, size) != 0)
            return 0;
        if (size == 8) *rp = __builtin_bswap64(tmp);
        else if (size == 4) *rp = (u64)__builtin_bswap32((u32)tmp);
        else *rp = (*rp & ~0xffffULL) | (u64)__builtin_bswap16((u16)tmp);
    } else {
        u64 v = *rp;
        if (size == 8) tmp = __builtin_bswap64(v);
        else if (size == 4) tmp = (u32)__builtin_bswap32((u32)v);
        else tmp = (u16)__builtin_bswap16((u16)v);
        if (raw_copy_user((void *)ea, &tmp, size) != 0)
            return 0;
    }

    regs[16] = ip + pos;
    return 1;
}
"""

TEST_HARNESS = C_CODE + r"""
#include <stdio.h>
#include <assert.h>
int main(void) {
    u64 regs[21]; u8 mem[256];
    memset(regs, 0, sizeof(regs)); memset(mem, 0, sizeof(mem));
    regs[17] = 0x33;
    u8 code1[] = { 0x0f, 0x38, 0xf1, 0x6b, 0x60,  0x44, 0x0f, 0x38, 0xf1, 0x63, 0x64 };
    regs[16] = (u64)code1; regs[5] = (u64)mem; regs[4] = 0x11223344ULL; regs[3] = 0xaabbccddULL;
    assert(emulate_movbe(regs) == 1 && *(u32 *)(mem + 0x60) == 0x44332211U);
    assert(emulate_movbe(regs) == 1 && *(u32 *)(mem + 0x64) == 0xddccbbaaU);
    u8 code2[] = { 0x0f, 0x38, 0xf0, 0x43, 0x60 };
    regs[16] = (u64)code2; regs[10] = 0xffffffff00000000ULL;
    assert(emulate_movbe(regs) == 1 && regs[10] == 0x11223344ULL);
    u8 code3[] = { 0x66, 0x0f, 0x38, 0xf0, 0x4b, 0x60 };
    *(u16 *)(mem + 0x60) = 0x3412; regs[16] = (u64)code3; regs[11] = 0xdeadbeefcafebabeULL;
    assert(emulate_movbe(regs) == 1 && regs[11] == 0xdeadbeefcafe1234ULL);
    u8 code4[] = { 0x4c, 0x0f, 0x38, 0xf0, 0x7c, 0x8c, 0x10 };
    *(u64 *)(mem + 0x20) = 0x0807060504030201ULL; regs[16] = (u64)code4; regs[19] = (u64)mem; regs[11] = 4;
    assert(emulate_movbe(regs) == 1 && regs[0] == 0x0102030405060708ULL);
    printf("HOST TESTS OK!\n");
    return 0;
}
"""

ASM_ALL = r"""
.section .text.movbe, "ax", @progbits
.globl movbe_entry
movbe_entry:
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp
    callq emulate_movbe
    movq %rbp, %rsp
    popq %rbp
    testl %eax, %eax
    jz 1f
    addq $8, %rsp
    jmp exc_invalid_op_exit
1:
    movq %rbx, %rdi
    jmp orig_error_get_trap_addr
"""

open(f"{SCRATCH}/movbe.c", "w").write(C_CODE)
open(f"{SCRATCH}/movbe_test.c", "w").write(TEST_HARNESS)
open(f"{SCRATCH}/movbe_entry.S", "w").write(ASM_ALL)

subprocess.run(["clang", "-O2", "-DHOST_TEST", f"{SCRATCH}/movbe_test.c", "-o", f"{SCRATCH}/movbe_test"], check=True)
subprocess.run([f"{SCRATCH}/movbe_test"], check=True)

# Compile C to assembly, concatenate with movbe_entry.S so internal calls are resolved by assembler!
subprocess.run([
    "clang", "--target=x86_64-unknown-linux-gnu", "-march=x86-64",
    "-Oz", "-mno-sse", "-mno-mmx", "-mno-sse2", "-mno-80387",
    "-mno-red-zone", "-mcmodel=kernel", "-fno-pie", "-fno-pic",
    "-fno-stack-protector", "-fno-asynchronous-unwind-tables",
    "-fno-jump-tables", "-fcf-protection=none",
    "-S", f"{SCRATCH}/movbe.c", "-o", f"{SCRATCH}/movbe_gen.s"
], check=True)

combined_s = ASM_ALL + "\n" + open(f"{SCRATCH}/movbe_gen.s").read()
open(f"{SCRATCH}/combined.S", "w").write(combined_s)

subprocess.run([
    "clang", "--target=x86_64-unknown-linux-gnu", "-march=x86-64",
    "-c", f"{SCRATCH}/combined.S", "-o", f"{SCRATCH}/combined.o"
], check=True)

# Parse ELF64 relocatable object combined.o to extract .text.movbe and resolve external relocs!
obj = open(f"{SCRATCH}/combined.o", "rb").read()
e_shoff = struct.unpack_from("<Q", obj, 0x28)[0]
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", obj, 0x3a)

def shdr(i):
    return struct.unpack_from("<IIQQQQIIQQ", obj, e_shoff + i * e_shentsize)

shstr_off = shdr(e_shstrndx)[4]
secs = {}
for i in range(e_shnum):
    s = shdr(i)
    end = obj.find(b"\x00", shstr_off + s[0])
    name = obj[shstr_off + s[0]:end].decode()
    secs[name] = (i, s)

code_idx, code_sh = secs[".text.movbe"]
code = bytearray(obj[code_sh[4] : code_sh[4] + code_sh[5]])
print(f"Compiled .text.movbe payload size: {len(code)} bytes (0x{len(code):x}) — max allowed: 0x440 (1088) bytes!")
assert len(code) <= 0x440, f"Payload too big: {len(code)}"

# Symbol table & strtab
_, sym_sh = secs[".symtab"]
_, str_sh = secs[".strtab"]
syms = []
for off in range(sym_sh[4], sym_sh[4] + sym_sh[5], 24):
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", obj, off)
    end = obj.find(b"\x00", str_sh[4] + st_name)
    sname = obj[str_sh[4] + st_name : end].decode()
    syms.append((sname, st_shndx, st_value))

BASE_VMA = 0xffffffff81e03bc0
EXT_TARGETS = {
    "copy_user_generic":        0xffffffff81565ce0,
    "exc_invalid_op_exit":      0xffffffff81b53593,
    "orig_error_get_trap_addr": 0xffffffff81214be7,
}

if ".rela.text.movbe" in secs:
    _, rela_sh = secs[".rela.text.movbe"]
    for off in range(rela_sh[4], rela_sh[4] + rela_sh[5], 24):
        r_offset, r_info, r_addend = struct.unpack_from("<QQq", obj, off)
        r_sym = r_info >> 32
        r_type = r_info & 0xffffffff
        sname, shndx, svalue = syms[r_sym]
        assert r_type in (2, 4), f"Unexpected reloc type {r_type} for {sname}"
        if shndx == code_idx:
            target_vma = BASE_VMA + svalue
        else:
            target_vma = EXT_TARGETS[sname]
        pc_vma = BASE_VMA + r_offset
        rel32 = (target_vma + r_addend) - pc_vma
        print(f"  Reloc @ +0x{r_offset:x} -> {sname} (0x{target_vma:x}): rel32={rel32:#x}")
        struct.pack_into("<i", code, r_offset, rel32)

# Patch arcvm_vmlinux.elf!
vmlinux = bytearray(open("/Users/magrani/Downloads/cros_temp/arcvm_vmlinux.elf", "rb").read())

# 1. Verify hook site at VMA 0xffffffff81b53567 (file offset 0xd53567)
hook_vma = 0xffffffff81b53567
hook_off = 0x200000 + (hook_vma - 0xffffffff81000000)
orig_call = bytes(vmlinux[hook_off : hook_off + 5])
assert orig_call == bytes.fromhex("e87b166cff"), f"Unexpected bytes at hook site: {orig_call.hex()}"

# 2. Write payload at VMA 0xffffffff81e03bc0 (file offset 0x1003bc0)
payload_off = 0x200000 + (BASE_VMA - 0xffffffff81000000)
assert all(b == 0 for b in vmlinux[payload_off : payload_off + len(code)])
vmlinux[payload_off : payload_off + len(code)] = code

# 3. Patch 5-byte callq at 0xffffffff81b53567 -> movbe_entry (BASE_VMA)
call_rel32 = BASE_VMA - (hook_vma + 5)
vmlinux[hook_off : hook_off + 5] = b"\xe8" + struct.pack("<i", call_rel32)

# 4. Also extend .text section header sh_size slightly to cover payload (for clean objdump)
ve_shoff = struct.unpack_from("<Q", vmlinux, 0x28)[0]
ve_shentsize = struct.unpack_from("<H", vmlinux, 0x3a)[0]
# Section 1 is .text; sh_size is at +0x20 inside Elf64_Shdr
new_text_size = (BASE_VMA - 0xffffffff81000000) + len(code)
struct.pack_into("<Q", vmlinux, ve_shoff + 1 * ve_shentsize + 0x20, new_text_size)

out_path = "/Users/magrani/Downloads/cros_temp/arcvm_vmlinux_patched.elf"
open(out_path, "wb").write(vmlinux)
print(f"Successfully wrote {out_path} ({len(vmlinux)} bytes)!")
