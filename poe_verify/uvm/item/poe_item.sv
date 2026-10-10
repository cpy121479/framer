// KO 激励事务（48B 报文 + 随路 pre_read）
class poe_ko_item extends uvm_sequence_item;
    rand bit [7:0]  da, sa, dp, sp, type_f, boe;
    rand bit [2:0]  pri;
    rand bit [12:0] sn;
    rand bit [31:0] poe_head, mem_head;
    bit [5:0]       pre_thid;     // 预发射目标线程号（由序列按平台分配规律给出）
    rand bit [3:0]  pre_strb;     // CW 窗 4 个表项各自一位
    rand bit [175:0] pre_data;    // 4×44bit 预发射数据
    bit [383:0]     ko_data;
    `uvm_object_utils(poe_ko_item)

    function new(string name = "poe_ko_item");
        super.new(name);
    endfunction

    // 随机字段 + 显式给出的 POE_HEAD / PRI / DA（多线程测试要能指定优先级与对账用的 DA）
    function void randomize_ko(input bit [31:0] head,
                               input bit [2:0]  pri_in = 3'd0,
                               input bit [7:0]  da_in  = 8'h00);
        da = da_in; sa = 8'hB2; dp = $urandom; sp = $urandom;
        type_f = $urandom; pri = pri_in; sn = $urandom % 8192; boe = $urandom;
        poe_head = head; mem_head = $urandom;
        pre_strb = $urandom & 4'hF;
        pre_data[43:0]    = $urandom;
        pre_data[87:44]   = $urandom;
        pre_data[131:88]  = $urandom;
        pre_data[175:132] = $urandom;
        ko_data = {da, dp, sa, sp, type_f, pri, sn[12:8], sn[7:0], boe,
                   poe_head, mem_head, 256'h0};
    endfunction
endclass

// 观测事件（monitor -> scoreboard）：**CSR 与 RF 各自独立成事件**（互不打包）
//   EV_CSR：ts 边界的 CSR 全表快照（按字节 0x00..0x47，见 rtl/poe_thread_bank.sv 地址表）
//   EV_RF ：ts 边界的 RF 全表快照（POE_RF_W/32 槽）
//   EV_KO ：线程出口 KO（EU 回刷结果）
//   EV_ERR：EU 错误标志（随结果拍有效；DUT/RM 必须一致且期望为 0）
class poe_ev_item extends uvm_object;
    typedef enum { EV_CSR, EV_RF, EV_KO, EV_ERR } kind_e;
    kind_e        kind;
    int           tid;
    int           ts;
    bit [8*72-1:0] csr;      // EV_CSR 用：整份 CSR（0x00..0x47）
    bit [POE_RF_W-1:0] rf;   // EV_RF 用：整份 RF 快照
    bit [383:0]    ko;       // EV_KO 用：48B 出口报文
    bit [3:0]      err;      // EV_ERR 用：EU 错误标志
    `uvm_object_utils(poe_ev_item)

    function new(string name = "poe_ev_item");
        super.new(name);
    endfunction
endclass
