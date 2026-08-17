//----------------------------------------------------------------------------
// fgotn_frame_item.sv - fgODUflex 帧事务
// 对应 ITU-T G.709 Annex M（fgODUflex 帧结构与开销）：
//   - 帧结构：4 行 x 3824 列，共 15296 字节；
//   - fgODUflex 开销区：列 1~14、1905~1918（FAS/MFAS/PM/TCM1/TCM2/DA）；
//   - fgOPUflex 开销区：列 15~16、1919~1920（PT/CSF/OMFI/JC/CFS 等）；
//   - 净荷区：列 17~1904、1921~3824，共 15168 字节。
// build_frame()/parse_frame() 负责开销字段与完整帧字节流互转。
//----------------------------------------------------------------------------
class fgotn_frame_item extends uvm_sequence_item;

  // ---- 帧常量 ----
  localparam int ROWS         = 4;
  localparam int COLS         = 3824;
  localparam int FRAME_BYTES  = ROWS * COLS;              // 15296
  localparam int PAYLOAD_BYTES= FRAME_BYTES - 128;        // 15168

  // ---- 完整帧字节流（driver 发送 / monitor 采集用）----
  bit [7:0] frame_bytes[];                                // 非随机，由 build_frame 生成

  // ---- 净荷与业务属性 ----
  rand bit [7:0] payload[$];                              // 净荷 15168 字节
  rand int unsigned p;                                    // fgOTN 带宽等级 p（1~119）
  // ---- 帧定位开销 ----
  rand bit [31:0] fas[];                                  // FAS0~FAS7，各 4 字节（动态数组，Verilator 兼容）
  rand bit [7:0]  mfas;                                   // 复帧定位信号（256 帧复帧）

  // ---- 通道监控开销 PM / TCM1 / TCM2 ----
  rand bit [7:0]  pm_tti[];
  rand bit [7:0]  pm_bip8;
  rand bit        pm_bdi;
  rand bit [3:0]  pm_bei;
  rand bit [2:0]  pm_stat;
  rand bit [7:0]  pm_dm;
  rand bit [15:0] pm_aps;

  rand bit [7:0]  tcm1_tti[];
  rand bit [7:0]  tcm1_bip8;
  rand bit        tcm1_bdi;
  rand bit [3:0]  tcm1_beibiae;
  rand bit [2:0]  tcm1_stat;
  rand bit [7:0]  tcm1_dm;
  rand bit [15:0] tcm1_aps;

  rand bit [7:0]  tcm2_tti[];
  rand bit [7:0]  tcm2_bip8;
  rand bit        tcm2_bdi;
  rand bit [3:0]  tcm2_beibiae;
  rand bit [2:0]  tcm2_stat;
  rand bit [7:0]  tcm2_dm;
  rand bit [15:0] tcm2_aps;

  // ---- DA 相位差累积开销（DA1~DA4，各 3 字节）----
  rand bit [23:0] da[];

  // ---- fgOPUflex 开销 ----
  rand bit [5:0]  opu_pt;                                 // 净荷类型（表 M.2 码点）
  rand bit        opu_csf;                                // 客户信号失效
  rand bit [3:0]  opu_omfi;                               // OPU 复帧指示（分组映射 11 帧复帧）
  rand bit [7:0]  mapping_oh[$];                          // 映射专用开销（JC/CFS/fgBWR RCOH 等）

  // ---- 错误注入开关（sequence 使用）----
  rand bit inject_bad_fas;                                // 置 1：破坏 FAS0 首字节
  rand bit inject_short_frame;                            // 置 1：驱动时提前结束帧（帧长错误）
  // ---- 约束 ----
  constraint c_p          { p inside {[1:119]}; }
  constraint c_payload    { payload.size() == PAYLOAD_BYTES; }
  constraint c_pt         { opu_pt inside {6'h01, 6'h02, 6'h03, 6'h05, 6'h07, 6'h08, 6'h09, 6'h3E}; }
  constraint c_errors     { inject_bad_fas == 1'b0; inject_short_frame == 1'b0; }

  `uvm_object_utils_begin(fgotn_frame_item)
    `uvm_field_int         (p,             UVM_ALL_ON)
    `uvm_field_array_int   (frame_bytes,   UVM_ALL_ON)
    `uvm_field_queue_int   (payload,       UVM_ALL_ON)
    `uvm_field_array_int   (fas,           UVM_ALL_ON)
    `uvm_field_int         (mfas,          UVM_ALL_ON)
    `uvm_field_array_int   (pm_tti,        UVM_ALL_ON)
    `uvm_field_int         (pm_bip8,       UVM_ALL_ON)
    `uvm_field_int         (pm_bdi,        UVM_ALL_ON)
    `uvm_field_int         (pm_bei,        UVM_ALL_ON)
    `uvm_field_int         (pm_stat,       UVM_ALL_ON)
    `uvm_field_int         (pm_dm,         UVM_ALL_ON)
    `uvm_field_int         (pm_aps,        UVM_ALL_ON)
    `uvm_field_array_int   (tcm1_tti,      UVM_ALL_ON)
    `uvm_field_int         (tcm1_bip8,     UVM_ALL_ON)
    `uvm_field_int         (tcm1_bdi,      UVM_ALL_ON)
    `uvm_field_int         (tcm1_beibiae,  UVM_ALL_ON)
    `uvm_field_int         (tcm1_stat,     UVM_ALL_ON)
    `uvm_field_int         (tcm1_dm,       UVM_ALL_ON)
    `uvm_field_int         (tcm1_aps,      UVM_ALL_ON)
    `uvm_field_array_int   (tcm2_tti,      UVM_ALL_ON)
    `uvm_field_int         (tcm2_bip8,     UVM_ALL_ON)
    `uvm_field_int         (tcm2_bdi,      UVM_ALL_ON)
    `uvm_field_int         (tcm2_beibiae,  UVM_ALL_ON)
    `uvm_field_int         (tcm2_stat,     UVM_ALL_ON)
    `uvm_field_int         (tcm2_dm,       UVM_ALL_ON)
    `uvm_field_int         (tcm2_aps,      UVM_ALL_ON)
    `uvm_field_array_int   (da,            UVM_ALL_ON)
    `uvm_field_int         (opu_pt,        UVM_ALL_ON)
    `uvm_field_int         (opu_csf,       UVM_ALL_ON)
    `uvm_field_int         (opu_omfi,      UVM_ALL_ON)
    `uvm_field_queue_int   (mapping_oh,    UVM_ALL_ON)
    `uvm_field_int         (inject_bad_fas,     UVM_ALL_ON)
    `uvm_field_int         (inject_short_frame, UVM_ALL_ON)
  `uvm_object_utils_end

  // 行/列（1 基）到字节索引（0 基）换算
  function int unsigned idx(input int row, input int col);
    return (row - 1) * COLS + (col - 1);
  endfunction

  function new(string name = "fgotn_frame_item");
    super.new(name);
  endfunction

  function void pre_randomize();
    // 默认开销初值，避免随机化后字段与协议语义偏差过大
    fas      = new[8];
    pm_tti   = new[32];
    tcm1_tti = new[32];
    tcm2_tti = new[32];
    da       = new[4];
    foreach (fas[i]) fas[i] = {8'hF6, 8'h28, 8'h28, 8'h28 ^ i[2:0]};
    mfas = 0;
    opu_pt   = 6'h02;     // 分组映射
    opu_csf  = 1'b0;
    opu_omfi = 4'h0;
    foreach (pm_tti[i])  pm_tti[i]  = i;
    foreach (tcm1_tti[i]) tcm1_tti[i] = i;
    foreach (tcm2_tti[i]) tcm2_tti[i] = i;
    foreach (da[i]) da[i] = 24'h00_00_00;
    foreach (mapping_oh[i]) mapping_oh[i] = 8'h00;
  endfunction

  function void post_randomize();
    build_frame();
  endfunction

  //------------------------------------------------------------------
  // 统一随机化入口：商业仿真器走约束随机化；
  // 兼容说明：Verilator 的 randomize() 恒返回 0（不支持约束求解），
  // 此时回退到 $urandom 直接填充字段。
  //------------------------------------------------------------------
  function void sv_randomize();
    if (!this.randomize()) begin
`ifdef VERILATOR
      `uvm_info(get_type_name(), "randomize() 不可用（Verilator），改用 $urandom 填充", UVM_HIGH)
      randomize_fallback();
`else
      `uvm_fatal(get_type_name(), "约束随机化失败")
`endif
    end
  endfunction

`ifdef VERILATOR
  function void randomize_fallback();
    fas      = new[8];
    pm_tti   = new[32];
    tcm1_tti = new[32];
    tcm2_tti = new[32];
    da       = new[4];
    p = 1 + ($urandom % 119);
    mfas = $urandom;
    foreach (fas[i]) fas[i] = {8'hF6, 8'h28, 8'h28, 8'h28 ^ i[2:0]};
    foreach (pm_tti[i])  pm_tti[i]  = $urandom;
    foreach (tcm1_tti[i]) tcm1_tti[i] = $urandom;
    foreach (tcm2_tti[i]) tcm2_tti[i] = $urandom;
    pm_bip8  = 8'h00; pm_bdi = 1'b0; pm_bei = 4'h0; pm_stat = 3'b0;
    pm_dm    = 8'h00; pm_aps = 16'h0000;
    tcm1_bip8 = 8'h00; tcm1_bdi = 1'b0; tcm1_beibiae = 4'h0; tcm1_stat = 3'b0;
    tcm1_dm  = 8'h00; tcm1_aps = 16'h0000;
    tcm2_bip8 = 8'h00; tcm2_bdi = 1'b0; tcm2_beibiae = 4'h0; tcm2_stat = 3'b0;
    tcm2_dm  = 8'h00; tcm2_aps = 16'h0000;
    foreach (da[i]) da[i] = 24'h00_00_00;
    opu_pt   = 6'h02;
    opu_csf  = 1'b0;
    opu_omfi = 4'h0;
    mapping_oh.delete();
    payload.delete();
    for (int i = 0; i < PAYLOAD_BYTES; i++) payload.push_back($urandom);
    inject_bad_fas     = 1'b0;
    inject_short_frame = 1'b0;
    build_frame();
  endfunction
`endif

  //------------------------------------------------------------------
  // build_frame：由开销字段 + 净荷组装完整帧字节流
  //------------------------------------------------------------------
  function void build_frame();
    int k;
    frame_bytes = new[FRAME_BYTES];
    foreach (frame_bytes[i]) frame_bytes[i] = 8'h55;   // 默认填充

    // ---- FAS0~FAS3：行 1~4，列 1~4；FAS4~FAS7：行 1~4，列 1905~1908 ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int b = 0; b < 4; b++) begin
        frame_bytes[idx(r, 1+b)]    = fas[r-1][31-8*b -: 8];
        frame_bytes[idx(r, 1905+b)] = fas[r+3][31-8*b -: 8];
      end
    end
    // ---- MFAS：行 1，列 7 ----
    frame_bytes[idx(1,7)] = mfas;
    // ---- PM：TTI 列 1909~1910；BDI(bit5)/STAT(bits6-8)/BEI(bits1-4) 位于列 12 ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1909; c <= 1910; c++) frame_bytes[idx(r,c)] = pm_tti[(r-1)*2 + (c-1909)];
      frame_bytes[idx(r,12)] = {pm_stat, pm_bdi, pm_bei};
    end
    frame_bytes[idx(3,11)] = pm_bip8;                    // PM BIP-8
    frame_bytes[idx(2,7)]  = pm_dm;                      // PM DM
    frame_bytes[idx(4,9)]  = pm_aps[15:8];               // PM APS 高字节
    frame_bytes[idx(4,10)] = pm_aps[7:0];                // PM APS 低字节
    // ---- TCM1：TTI 列 1913~1914；列 13 = {STAT, BDI, BEI} ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1913; c <= 1914; c++) frame_bytes[idx(r,c)] = tcm1_tti[(r-1)*2 + (c-1913)];
      frame_bytes[idx(r,13)] = {tcm1_stat, tcm1_bdi, tcm1_beibiae};
    end
    frame_bytes[idx(3,8)] = tcm1_bip8;
    frame_bytes[idx(2,6)] = tcm1_dm;
    frame_bytes[idx(4,7)] = tcm1_aps[15:8];
    frame_bytes[idx(4,8)] = tcm1_aps[7:0];
    // ---- TCM2：TTI 列 1911~1912；列 13 与 TCM1 合并（BIAE bits5-8/STAT bits2-4/BDI bit1）----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1911; c <= 1912; c++) frame_bytes[idx(r,c)] = tcm2_tti[(r-1)*2 + (c-1911)];
      frame_bytes[idx(r,13)] |= {tcm2_beibiae, tcm2_stat, tcm2_bdi};
    end
    frame_bytes[idx(3,5)] = tcm2_bip8;
    frame_bytes[idx(2,5)] = tcm2_dm;
    frame_bytes[idx(4,5)] = tcm2_aps[15:8];
    frame_bytes[idx(4,6)] = tcm2_aps[7:0];
    // ---- DA1~DA4：行 1~4，列 1915~1917（斜向分布）----
    for (int i = 0; i < 4; i++) begin
      frame_bytes[idx(i+1, 1915)]    = da[i][23:16];
      frame_bytes[idx(i%4 + 1, 1916)] = da[i][15:8];
      frame_bytes[idx((i+1)%4 + 1, 1917)] = da[i][7:0];
    end
    // ---- fgOPUflex 开销：行 4 列 15 = {CSF, RES, PT}；OMFI 位于列 16/1920 的 bits5-8 ----
    frame_bytes[idx(4,15)] = {opu_csf, 1'b0, opu_pt};
    for (int r = 1; r <= ROWS; r++) begin
      frame_bytes[idx(r,16)]   = {4'h0, opu_omfi};
      frame_bytes[idx(r,1920)] = {4'h0, opu_omfi};
    end
    if (mapping_oh.size() > 0)
      frame_bytes[idx(1,15)] = mapping_oh[0];            // 映射开销示例位置（行1列15）
    // ---- 净荷区：列 17~1904（前半）与 1921~3824（后半）----
    k = 0;
    for (int r = 1; r <= ROWS; r++)
      for (int c = 17; c <= 1904; c++) frame_bytes[idx(r,c)] = payload[k++];
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1921; c <= 3824; c++) frame_bytes[idx(r,c)] = payload[k++];

    // ---- BIP-8：对 fgOPUflex 区（列 15~1904、1919~3824）计算 ----
    calc_bip8();
    frame_bytes[idx(3,11)] = pm_bip8;
    frame_bytes[idx(3,8)]  = tcm1_bip8;
    frame_bytes[idx(3,5)]  = tcm2_bip8;

    // ---- 错误注入 ----
    if (inject_bad_fas) frame_bytes[0] = ~frame_bytes[0];
  endfunction

  //------------------------------------------------------------------
  // calc_bip8：位交错奇偶校验（与 G.709 表 15-x 语义一致）
  // 说明：标准中 BIP-8 是对第 i 帧计算、插入第 i+2 帧，此处简化为同帧计算。
  //------------------------------------------------------------------
  function void calc_bip8();
    bit [7:0] b;
    b = 8'h00;
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 15; c <= 1904; c++) b ^= frame_bytes[idx(r,c)];
      for (int c = 1919; c <= 3824; c++) b ^= frame_bytes[idx(r,c)];
    end
    pm_bip8  = b;
    tcm1_bip8 = b;
    tcm2_bip8 = b;
  endfunction

  //------------------------------------------------------------------
  // parse_frame：从帧字节流解析开销字段（monitor 使用）
  //------------------------------------------------------------------
  function void parse_frame();
    int k;
    if (frame_bytes.size() != FRAME_BYTES) begin
      `uvm_warning(get_type_name(), $sformatf("帧长度异常：%0d（期望 %0d）", frame_bytes.size(), FRAME_BYTES))
      return;
    end
    // 确保开销动态数组已分配（monitor 端 item 未走 pre_randomize）
    fas      = new[8];
    pm_tti   = new[32];
    tcm1_tti = new[32];
    tcm2_tti = new[32];
    da       = new[4];
    // FAS / MFAS
    for (int r = 1; r <= ROWS; r++) begin
      fas[r-1] = {frame_bytes[idx(r,1)],  frame_bytes[idx(r,2)],
                  frame_bytes[idx(r,3)],  frame_bytes[idx(r,4)]};
      fas[r+3] = {frame_bytes[idx(r,1905)], frame_bytes[idx(r,1906)],
                  frame_bytes[idx(r,1907)], frame_bytes[idx(r,1908)]};
    end
    mfas = frame_bytes[idx(1,7)];
    // PM
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1909; c <= 1910; c++) pm_tti[(r-1)*2 + (c-1909)] = frame_bytes[idx(r,c)];
    pm_bip8 = frame_bytes[idx(3,11)];
    pm_dm   = frame_bytes[idx(2,7)];
    pm_aps  = {frame_bytes[idx(4,9)], frame_bytes[idx(4,10)]};
    for (int r = 1; r <= ROWS; r++) begin
      pm_bdi  = frame_bytes[idx(r,12)][4];
      pm_stat = frame_bytes[idx(r,12)][7:5];
    end
    pm_bei = frame_bytes[idx(3,12)][3:0];
    // TCM1 / TCM2（字节级提取，位级拆分从简）
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1913; c <= 1914; c++) tcm1_tti[(r-1)*2 + (c-1913)] = frame_bytes[idx(r,c)];
    tcm1_bip8 = frame_bytes[idx(3,8)];
    tcm1_dm   = frame_bytes[idx(2,6)];
    tcm1_aps  = {frame_bytes[idx(4,7)], frame_bytes[idx(4,8)]};
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1911; c <= 1912; c++) tcm2_tti[(r-1)*2 + (c-1911)] = frame_bytes[idx(r,c)];
    tcm2_bip8 = frame_bytes[idx(3,5)];
    tcm2_dm   = frame_bytes[idx(2,5)];
    tcm2_aps  = {frame_bytes[idx(4,5)], frame_bytes[idx(4,6)]};
    // DA
    for (int i = 0; i < 4; i++)
      da[i] = {frame_bytes[idx(i+1,1915)], frame_bytes[idx(i%4+1,1916)], frame_bytes[idx((i+1)%4+1,1917)]};
    // fgOPUflex
    opu_csf  = frame_bytes[idx(4,15)][7];
    opu_pt   = frame_bytes[idx(4,15)][5:0];
    opu_omfi = frame_bytes[idx(1,16)][7:4];
    // 净荷提取
    payload.delete();
    k = 0;
    for (int r = 1; r <= ROWS; r++)
      for (int c = 17; c <= 1904; c++) payload.push_back(frame_bytes[idx(r,c)]);
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1921; c <= 3824; c++) payload.push_back(frame_bytes[idx(r,c)]);
  endfunction

  function string oh_summary();
    return $sformatf("mfas=%02x pt=%02x csf=%b pm_bip8=%02x pm_bei=%x pm_stat=%x tcm1_bip8=%02x tcm2_bip8=%02x da1=%06x",
                     mfas, opu_pt, opu_csf, pm_bip8, pm_bei, pm_stat, tcm1_bip8, tcm2_bip8, da[0]);
  endfunction

endclass
