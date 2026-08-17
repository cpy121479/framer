//----------------------------------------------------------------------------
// fgotn_frame_item.sv — fgODUflex 帧事务
//----------------------------------------------------------------------------
// 与 ITU-T G.709 Annex M（fgODUflex 帧结构与开销）对应：
//  - 帧结构：4 行 x 3824 列，共 15296 字节；
//  - 开销区：列 1~14、1905~1918（FAS/MFAS/PM/TCM1/TCM2/DA）；
//  - fgOPUflex 开销：列 15~16、1919~1920（PT/CSF/OMFI/JC/CFS 等）；
//  - 净荷区：列 17~1904、1921~3824，共 15168 字节。
// 事务同时承载完整帧字节流（frame_bytes）与解析后的开销字段，
// build_frame()/parse_frame() 负责两者互转。
//----------------------------------------------------------------------------
class fgotn_frame_item extends uvm_sequence_item;

  // ---- 帧常量 ----
  localparam int ROWS         = 4;
  localparam int COLS         = 3824;
  localparam int FRAME_BYTES  = ROWS * COLS;              // 15296
  localparam int PAYLOAD_BYTES= FRAME_BYTES - 128;        // 15168

  // ---- 完整帧字节流（monitor 采集 / driver 发送用）----
  bit [7:0] frame_bytes[];                                // 非随机，由 build_frame 生成

  // ---- 净荷与业务属性 ----
  rand bit [7:0] payload[$];                              // 净荷 15168 字节
  rand int unsigned p;                                    // fgOTN 带宽等级 p（1~119）

  // ---- 帧定位开销 ----
  rand bit [31:0] fas[8];                                 // FAS0~FAS7，各 4 字节
  rand bit [7:0]  mfas;                                   // 复帧定位信号（256 帧复帧）

  // ---- 通道监控开销 PM / TCM1 / TCM2 ----
  rand bit [7:0]  pm_tti[32];
  rand bit [7:0]  pm_bip8;
  rand bit        pm_bdi;
  rand bit [3:0]  pm_bei;
  rand bit [2:0]  pm_stat;
  rand bit [7:0]  pm_dm;
  rand bit [15:0] pm_aps;

  rand bit [7:0]  tcm1_tti[32];
  rand bit [7:0]  tcm1_bip8;
  rand bit        tcm1_bdi;
  rand bit [3:0]  tcm1_beibiae;
  rand bit [2:0]  tcm1_stat;
  rand bit [7:0]  tcm1_dm;
  rand bit [15:0] tcm1_aps;

  rand bit [7:0]  tcm2_tti[32];
  rand bit [7:0]  tcm2_bip8;
  rand bit        tcm2_bdi;
  rand bit [3:0]  tcm2_beibiae;
  rand bit [2:0]  tcm2_stat;
  rand bit [7:0]  tcm2_dm;
  rand bit [15:0] tcm2_aps;

  // ---- DA 相位差累积开销（DA1~DA4，各 3 字节）----
  rand bit [23:0] da[4];

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

  // 行/列(1 基) 到字节索引(0 基) 的换算
  function int unsigned idx(input int row, input int col);
    return (row - 1) * COLS + (col - 1);
  endfunction

  function void pre_randomize();
    // 默认开销初值，避免随机化后字段与协议语义偏差过大
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
    // ---- PM ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1909; c <= 1910; c++) frame_bytes[idx(r,c)] = pm_tti[(r-1)*2 + (c-1909)];
      // BDI(bit5) + STAT(bits6-8) 位于列 12
      frame_bytes[idx(r,12)] = {pm_stat, 1'b0, pm_bdi, pm_bei /* 仅行 3 使用，此处按位写入 */};
    end
    frame_bytes[idx(3,11)] = pm_bip8;                    // PM BIP-8
    frame_bytes[idx(2,7)]  = pm_dm;                      // PM DM
    frame_bytes[idx(4,9)]  = pm_aps[15:8];               // PM APS 高字节
    frame_bytes[idx(4,10)] = pm_aps[7:0];                // PM APS 低字节
    // ---- TCM1 ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1913; c <= 1914; c++) frame_bytes[idx(r,c)] = tcm1_tti[(r-1)*2 + (c-1913)];
      frame_bytes[idx(r,13)] = {tcm1_stat, 1'b0, tcm1_bdi, tcm1_beibiae};
    end
    frame_bytes[idx(3,8)] = tcm1_bip8;
    frame_bytes[idx(2,6)] = tcm1_dm;
    frame_bytes[idx(4,7)] = tcm1_aps[15:8];
    frame_bytes[idx(4,8)] = tcm1_aps[7:0];
    // ---- TCM2 ----
    for (int r = 1; r <= ROWS; r++) begin
      for (int c = 1911; c <= 1912; c++) frame_bytes[idx(r,c)] = tcm2_tti[(r-1)*2 + (c-1911)];
      frame_bytes[idx(r,13)] |= {tcm2_beibiae, 1'b0, tcm2_bdi, tcm2_stat}; // 与 TCM1 合并（bit1-4 / bit5-8）
    end
    frame_bytes[idx(3,5)] = tcm2_bip8;
    frame_bytes[idx(2,5)] = tcm2_dm;
    frame_bytes[idx(4,5)] = tcm2_aps[15:8];
    frame_bytes[idx(4,6)] = tcm2_aps[7:0];
    // ---- DA1~DA4：行 1~4，列 1915~1917（斜向分布）----
    for (int i = 0; i < 4; i++) begin
      frame_bytes[idx(i+1, 1915)] = da[i][23:16];
      frame_bytes[idx(i%4 + 1, 1916)] = da[i][15:8];
      frame_bytes[idx((i+1)%4 + 1, 1917)] = da[i][7:0];
    end
    // ---- fgOPUflex 开销：行 4 列 15 = {CSF, RES, PT} ----
    frame_bytes[idx(4,15)] = {opu_csf, 1'b0, opu_pt};
    for (int r = 1; r <= ROWS; r++) begin
      frame_bytes[idx(r,16)]   = opu_omfi;               // OMFI（简化：同值写入）
      frame_bytes[idx(r,1920)] = opu_omfi;
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
  // 注：标准中 BIP-8 是对第 i 帧计算、插入第 i+2 帧，此处简化为同帧。
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
    // FAS / MFAS
    for (int r = 1; r <= ROWS; r++) begin
      for (int b = 0; b < 4; b++) begin
        fas[r-1][31-8*b -: 8] = frame_bytes[idx(r,1+b)];
        fas[r+3][31-8*b -: 8] = frame_bytes[idx(r,1905+b)];
      end
    end
    mfas = frame_bytes[idx(1,7)];
    // PM
    for (int r = 1; r <= ROWS; r++)
      for (int c = 1909; c <= 1910; c++) pm_tti[(r-1)*2 + (c-1909)] = frame_bytes[idx(r,c)];
    pm_bip8 = frame_bytes[idx(3,11)];
    pm_dm   = frame_bytes[idx(2,7)];
    pm_aps  = {frame_bytes[idx(4,9)], frame_bytes[idx(4,10)]};
    for (int r = 1; r <= ROWS; r++) begin
      pm_bdi  = frame_bytes[idx(r,12)][5];
      pm_stat = frame_bytes[idx(r,12)][8:6];
    end
    pm_bei = frame_bytes[idx(3,12)][4:1];
    // TCM1 / TCM2（简化为直接取字节，不做位级拆分）
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
    opu_csf  = frame_bytes[idx(4,15)][8];
    opu_pt   = frame_bytes[idx(4,15)][6:1];
    opu_omfi = frame_bytes[idx(1,16)][4:1];
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
