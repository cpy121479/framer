// 多流输入 driver：按 item.stream 驱动对应端口组（valid/ready 握手）
class koa_driver extends uvm_driver #(koa_item);
  `uvm_component_utils(koa_driver)

  function new(string name = "koa_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    koa_item req;
    forever begin
      seq_item_port.get_next_item(req);
      while (!ko_pkg::g_reset_done) @(posedge ko_pkg::g_tb_cfg.vif.clk);
      @(ko_pkg::g_tb_cfg.vif.drv_cb);
      case (req.stream)
        ST_OH_EXT: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_vld  <= (1 << req.plane);
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_data <= (req.ko_data << (req.plane * 384));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_pri  <= (req.pri << (req.plane * 3));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_cid  <= (req.cid << (req.plane * 17));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_pos  <= (req.pos << (req.plane * 3));
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_rdy[req.plane] !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_e_vld <= '0;
        end
        ST_OH_INS: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_vld  <= (1 << req.plane);
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_data <= (req.ko_data << (req.plane * 384));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_pri  <= (req.pri << (req.plane * 3));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_cid  <= (req.cid << (req.plane * 17));
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_pos  <= (req.pos << (req.plane * 3));
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_rdy[req.plane] !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.oh_i_vld <= '0;
        end
        ST_APS_EXT: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_vld  <= (1 << req.plane);
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_data <= (req.ko_data << (req.plane * 384));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_pri  <= (req.pri << (req.plane * 3));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_cid  <= (req.cid << (req.plane * 17));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_pos  <= (req.pos << (req.plane * 3));
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_rdy[req.plane] !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_e_vld <= '0;
        end
        ST_APS_INS: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_vld  <= (1 << req.plane);
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_data <= (req.ko_data << (req.plane * 384));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_pri  <= (req.pri << (req.plane * 3));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_cid  <= (req.cid << (req.plane * 17));
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_pos  <= (req.pos << (req.plane * 3));
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_rdy[req.plane] !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.aps_i_vld <= '0;
        end
        ST_ALM: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_vld  <= (1 << req.plane);
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_data <= (req.ko_data << (req.plane * 384));
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_pri  <= (req.pri << (req.plane * 3));
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_cid  <= (req.cid << (req.plane * 17));
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_pos  <= (req.pos << (req.plane * 3));
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.alm_rdy[req.plane] !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.alm_vld <= '0;
        end
        ST_UART_EXT: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.u_e_vld  <= 1'b1;
          ko_pkg::g_tb_cfg.vif.drv_cb.u_e_data <= req.ko_data;
          ko_pkg::g_tb_cfg.vif.drv_cb.u_e_pri  <= req.pri;
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.u_e_rdy !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.u_e_vld <= 1'b0;
        end
        default: begin
          ko_pkg::g_tb_cfg.vif.drv_cb.u_i_vld  <= 1'b1;
          ko_pkg::g_tb_cfg.vif.drv_cb.u_i_data <= req.ko_data;
          ko_pkg::g_tb_cfg.vif.drv_cb.u_i_pri  <= req.pri;
          do @(ko_pkg::g_tb_cfg.vif.drv_cb);
          while (ko_pkg::g_tb_cfg.vif.drv_cb.u_i_rdy !== 1'b1);
          ko_pkg::g_tb_cfg.vif.drv_cb.u_i_vld <= 1'b0;
        end
      endcase
      seq_item_port.item_done();
      @(ko_pkg::g_tb_cfg.vif.drv_cb);   // 一拍空闲
    end
  endtask
endclass
