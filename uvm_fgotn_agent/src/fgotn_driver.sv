//----------------------------------------------------------------------------
// fgotn_driver.sv — 帧驱动器（active 模式）
//----------------------------------------------------------------------------
// 将 fgotn_frame_item 的 frame_bytes 按字节流 valid/ready 握手送出，
// 首字节拉高 tstart，末字节拉高 tend。
//----------------------------------------------------------------------------
class fgotn_driver extends uvm_driver #(fgotn_frame_item);

  fgotn_agent_config cfg;
  virtual fgotn_if vif;

  `uvm_component_utils(fgotn_driver)

  function new(string name = "fgotn_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = fgotn_agent_config::get_config(this);
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    fgotn_frame_item req;
    forever begin
      seq_item_port.get_next_item(req);
      drive_frame(req);
      seq_item_port.item_done();
    end
  endtask

  task drive_frame(fgotn_frame_item item);
    int unsigned nbytes = item.frame_bytes.size();
    int unsigned end_byte;
    int unsigned gap = cfg.inter_frame_gap;

    if (item.inject_short_frame) begin
      end_byte = nbytes / 2;                 // 提前截断，制造帧长错误
      `uvm_info(get_type_name(), "错误注入：帧提前结束（短帧）", UVM_MEDIUM)
    end else begin
      end_byte = nbytes;
    end

    for (int i = 0; i < end_byte; i++) begin
      vif.drv_cb.tdata  <= item.frame_bytes[i];
      vif.drv_cb.tvalid <= 1'b1;
      vif.drv_cb.tstart <= (i == 0);
      vif.drv_cb.tend   <= (i == end_byte - 1);
      do begin
        @(vif.drv_cb);
      end while (!vif.drv_cb.tready);
    end

    // 帧尾清理
    vif.drv_cb.tvalid <= 1'b0;
    vif.drv_cb.tstart <= 1'b0;
    vif.drv_cb.tend   <= 1'b0;
    repeat (gap) @(vif.drv_cb);
    `uvm_info(get_type_name(), $sformatf("已驱动 1 帧：%0d 字节，%s", end_byte, item.oh_summary()), UVM_HIGH)
  endtask

endclass
