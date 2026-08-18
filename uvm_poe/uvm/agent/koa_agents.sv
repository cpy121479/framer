// KOA agent：3 个业务源各配一个 driver + sequencer（fgOTN 开销 / X2X / 串口），
// 跨业务源并发（最大 3 路 vld），同业务源多流共享 sequencer（item 串行、不独立）；
// 输入/输出 monitor 每拍扫 7 组端口（vld && rdy 握手采样）
class koa_agent extends uvm_agent;
    koa_driver drv[3]; // 每个业务源一个 driver（stream_group=索引）
    koa_in_monitor in_mon;
    koa_out_monitor out_mon;
    uvm_sequencer #(koa_item) sqr[3]; // 每个业务源一个 sequencer
    uvm_analysis_port #(koa_item) ap;
    `uvm_component_utils(koa_agent)

    function new(string name = "koa_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        for (int i = 0; i < 3; i++) begin
            drv[i] = koa_driver::type_id::create($sformatf("drv_%0d", i), this);
            sqr[i] = uvm_sequencer#(koa_item)::type_id::create($sformatf("sqr_%0d", i), this);
            drv[i].stream_group = i;
        end
        in_mon = koa_in_monitor::type_id::create("in_mon", this);
        out_mon = koa_out_monitor::type_id::create("out_mon", this);
        ap = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int i = 0; i < 3; i++)
            drv[i].seq_item_port.connect(sqr[i].seq_item_export);
        in_mon.ap.connect(ap);
        out_mon.ap.connect(ap);
    endfunction
endclass
