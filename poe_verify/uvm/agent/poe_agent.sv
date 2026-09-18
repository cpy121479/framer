// ============================================================================
// agent 三件套：sequencer + driver（+ 引用 seq/item 所在的文件）
//   · 激励事务：item/poe_item.sv   —— poe_ko_item（48B KO + pre_read）
//   · 激励序列：seq/poe_ko_seq.sv  —— poe_ko_seq（随机 DA/SA/PRI/head）
//   · 驱动：就是把 poe_ko_item 变成 ko_if 上的 vld/data 时序（见下）
// ============================================================================

// driver：驱动 ko_if（顶层分叉给 DUT 与 RM，所以只有这一个 driver）
class poe_ko_driver extends uvm_driver #(poe_ko_item);
    virtual poe_if vif;
    `uvm_component_utils(poe_ko_driver)

    function new(string name = "poe_ko_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    task run_phase(uvm_phase phase);
        vif = poe_uvm_pkg::g_vif;
        forever begin
            seq_item_port.get_next_item(req);
            wait (vif.ko_rdy);          // 池有空闲槽才发（没有就保持等待）
            @(negedge vif.clk);         // 低电平驱动，避开 posedge 竞争
            vif.ko_data   <= req.ko_data;
            vif.pre_vld   <= 1'b1;              // csr 预发射口：与 KO 建线程同拍
            vif.pre_thid  <= req.pre_thid;
            vif.pre_strb  <= req.pre_strb;
            vif.pre_data  <= req.pre_data;
            vif.ko_vld    <= 1'b1;
            @(negedge vif.clk);         // 中间跨一个 posedge：池正好受理一次
            vif.ko_vld  <= 1'b0;
            vif.pre_vld <= 1'b0;
            seq_item_port.item_done();
        end
    endtask
endclass

class poe_ko_agent extends uvm_agent;
    poe_ko_driver    drv;
    uvm_sequencer #(poe_ko_item) sqr;
    `uvm_component_utils(poe_ko_agent)

    function new(string name = "poe_ko_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = poe_ko_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(poe_ko_item)::type_id::create("sqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
