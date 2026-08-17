// GCC 16.1 (MinGW/ucrt64) 回归的本地修复：
// libstdc++ bug 125359 —— 编译器会生成 std::string 移动构造的 C4 变体引用
// (_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC4EOS4_)，
// 但 libstdc++ 只导出 C1/C2 变体，导致链接报 undefined reference。
// 这里补一个等价的 C4 定义，转发到标准 C1 移动构造。
// 上游修复后可删除本文件。
#include <cstdio>
#include <string>
#include <vector>
#include <windows.h>
#include "vpi_user.h"

// 引用 libstdc++ 已导出的 C1 移动构造符号（不通过构造函数语法调用，
// 否则 GCC 16.1 MinGW 会再次生成 C4 引用，导致桩函数尾调用自递归）。
extern "C" void c1_string_move_ctor(void* self, void* rhs)
    __asm__("_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC1EOS4_");

extern "C" void gcc16_c4_string_move_ctor(void* self, void* rhs)
    __asm__("_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC4EOS4_");

extern "C" void gcc16_c4_string_move_ctor(void* self, void* rhs) {
    c1_string_move_ctor(self, rhs);
}

// VPI 标准要求仿真器提供 vlog_startup_routines 空结尾数组；
// Verilator 只生成引用而不提供定义，这里补上。
extern "C" void (*vlog_startup_routines[])(void) = { 0 };

// 不启用 --vpi 时 Verilator 不提供 vpi_get_vlog_info。
// UVM 的 uvm_svcmd_dpi.c 用它获取 argc/argv（命令行参数枚举），
// 这里用 Windows CRT 的 __argc/__argv 实现真实取值。
extern "C" int vpi_get_vlog_info(p_vpi_vlog_info info) {
    static std::vector<std::string> args_storage;
    static std::vector<char*> args_ptrs;

    int wargc = 0;
    LPWSTR* wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
    if (!wargv) return 0;

    args_storage.clear();
    args_ptrs.clear();
    for (int i = 0; i < wargc; ++i) {
        int len = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, nullptr, 0, nullptr, nullptr);
        std::string s(len, '\0');
        WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, &s[0], len, nullptr, nullptr);
        if (!s.empty() && s.back() == '\0') s.pop_back();
        args_storage.push_back(s);
    }
    LocalFree(wargv);

    args_ptrs.reserve(args_storage.size());
    for (auto& s : args_storage) args_ptrs.push_back(&s[0]);

    info->argc = wargc;
    info->argv = args_ptrs.data();
    info->product = const_cast<PLI_BYTE8*>("Verilator");
    info->version = const_cast<PLI_BYTE8*>("5.050");
    return 1;
}

// 本工具链在进程退出清理时存在崩溃（GCC 16.1 MinGW 相关问题），
// 为避免缓冲的仿真输出在退出时丢失，把 stdout 设为无缓冲。
static int init_unbuffered_stdout() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    return 0;
}
static const int g_unbuffered_stdout = init_unbuffered_stdout();
