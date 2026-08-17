//----------------------------------------------------------------------
// Copyright 2010-2018 Cadence Design Systems, Inc.
// Copyright 2023 Intel Corporation
// Copyright 2010-2017 Mentor Graphics Corporation
// Copyright 2013-2024 NVIDIA Corporation
// Copyright 2010-2013 Synopsys, Inc.
//   All Rights Reserved Worldwide
//
//   Licensed under the Apache License, Version 2.0 (the
//   "License"); you may not use this file except in
//   compliance with the License.  You may obtain a copy of
//   the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in
//   writing, software distributed under the License is
//   distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
//   CONDITIONS OF ANY KIND, either express or implied.  See
//   the License for the specific language governing
//   permissions and limitations under the License.
//----------------------------------------------------------------------

//----------------------------------------------------------------------
// Git details (see DEVELOPMENT.md):
//
// $File$
// $Rev$
// $Hash$
//
//----------------------------------------------------------------------


//
// Top-level file that includes all of the C/C++ files required
// by UVM
//
// The C code may be compiled by compiling this top file only,
// or by compiling individual files then linking them together.
//

#ifdef __cplusplus
extern "C" {
#endif

#include <stdlib.h>
#include "uvm_dpi.h"

// Avoid -Wmissing-definitions
 int uvm_hdl_check_path(char *path);
 int uvm_hdl_read(char *path, p_vpi_vecval value);
 int uvm_hdl_deposit(char *path, p_vpi_vecval value);
 int uvm_hdl_force(char *path, p_vpi_vecval value);
 int uvm_hdl_release_and_read(char *path, p_vpi_vecval value);
 int uvm_hdl_release(char *path);
 void push_data(int lvl,char *entry, int cmd);
 void walk_level(int lvl, int argc, char**argv,int cmd);
 const char *uvm_dpi_get_next_arg_c (int init);
 extern char* uvm_dpi_get_tool_name_c ();
 extern char* uvm_dpi_get_tool_version_c ();

  extern char* uvm_re_buffer();
  extern const char* uvm_re_deglobbed(const char *glob, unsigned char with_brackets);
  extern void uvm_re_free(regex_t* handle);
  extern regex_t* uvm_re_comp(const char* re, unsigned char deglob);
  extern int uvm_re_exec(regex_t* rexp, const char *str);
  extern regex_t* uvm_re_compexec(const char* re, const char* str, unsigned char deglob, int* exec_ret);
  
#include "uvm_common.c"
#include "uvm_regex.cc"
#include "uvm_hdl.c"
#include "uvm_svcmd_dpi.c"
// 本地修改（Verilator 兼容）：不引入 uvm_hdl_polling.c。
// 该文件依赖 VPI 回调（vpi_register_cb 等），而 Verilator 5.050
// 在 Windows 上启用 --vpi 运行时会段错误；本平台也不使用 HDL 轮询。
// #include "uvm_hdl_polling.c"


#ifdef __cplusplus
}
#endif
