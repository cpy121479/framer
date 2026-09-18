// ============================================================================
// KO 激励序列：产生 n_ko 个 KO 事务（48B 报文 + 随路 pre_read）
//   head = 线程程序基址（宏指令存储的 ts 行号），由 KO 行 2 的 POE_HEAD 携带
//   第 i 个 KO：PRI = 3-i（越后来越高优先级），DA = 0x10+i（便于对账）
//              预发射口 thid = i（平台按最小空闲槽分配），strb/data 随机
//   其余字段随机：DP/SP/TYPE/SN/B-E-LBO
// ============================================================================
class poe_ko_seq extends uvm_sequence #(poe_ko_item);
    int unsigned n_ko = 2;          // 默认 2 个 KO = 2 个并发线程（先不铺更多）
    bit [31:0]   head = 32'd0;
    // 记录每个 KO 的预发射数据，供 test 核对 CW 窗（最多 8 个 KO）
    bit [5:0]   pre_thid_q [8];
    bit [3:0]   pre_strb_q [8];
    bit [175:0] pre_data_q [8];
    `uvm_object_utils(poe_ko_seq)

    function new(string name = "poe_ko_seq");
        super.new(name);
    endfunction

    task body();
        poe_ko_item it;
        for (int i = 0; i < int'(n_ko); i++) begin
            it = poe_ko_item::type_id::create($sformatf("ko%0d", i));
            it.randomize_ko(head,
                            (i == 0) ? 3'd3 : 3'd1,   // KO0 pri=3，KO1 pri=1（1 更高）
                            8'h10 + i[7:0]);          // DA 每个 KO 不同，出口 KO 便于对账
            it.pre_thid   = i[5:0];                   // 平台按最小空闲槽分配：KO i → tid i
            pre_thid_q[i] = it.pre_thid;
            pre_strb_q[i] = it.pre_strb;
            pre_data_q[i] = it.pre_data;
            start_item(it);
            finish_item(it);
        end
    endtask
endclass
