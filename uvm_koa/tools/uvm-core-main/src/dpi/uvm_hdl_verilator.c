// 本地新增：Verilator 下 UVM HDL DPI 的桩实现。
// 本仿真平台不调用 uvm_hdl_* 系列函数；这些桩仅保证链接通过，
// 且行为为"路径不存在/操作失败"，与未定义后端一致。
#ifndef UVM_HDL_VERILATOR_C
#define UVM_HDL_VERILATOR_C

int uvm_hdl_check_path(char *path) { (void)path; return 0; }
int uvm_hdl_deposit(char *path, p_vpi_vecval value) { (void)path; (void)value; return 0; }
int uvm_hdl_force(char *path, p_vpi_vecval value) { (void)path; (void)value; return 0; }
int uvm_hdl_release_and_read(char *path, p_vpi_vecval value) { (void)path; (void)value; return 0; }
int uvm_hdl_release(char *path) { (void)path; return 0; }
int uvm_hdl_read(char *path, p_vpi_vecval value) { (void)path; (void)value; return 0; }

#endif
